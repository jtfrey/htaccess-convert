#!/usr/bin/perl
#
# htaccess-convert
#
# Convert old UD htaccess files to corrected Apache 2.4 syntax
#

use strict;
use 5.010;

use Data::Dumper qw(Dumper);
use Scalar::Util qw(reftype);
use Getopt::Long;

#
# Hash of ignored commands:
#
my %ignore = (
      'authtype'            => 1,
      'authname'            => 1,
      'authbasicprovider'   => 1,
    );

#
# The HTTP methods that MUST be accounted for in htaccess files:
#
my @mandatory_methods = qw(GET POST);

#
# Map our lowercase'd tag form to the "pretty" form in output:
#
my %require_group_pretty = (
				'requireall' => 'RequireAll',
				'requireany' => 'RequireAny',
				'requirenone' => 'RequireNone'
			);

#
# @function usage($rc)
#
# Display a simple help summary to stdout and end the progrm.  The single
# argument, $rc, is the exit value for the program.
#
sub usage
{
  my( $rc ) = @_;
  print "
usage: $0 {options}

  --verbose, -v           increase level of verbosity
  --quiet, -q             no verbosity
  --help, -h              display this help screen
  
  --whitespace, -w        preserve blank lines (by default they are discarded)
  --no-comments, -c       remove comments

  --input=<filename>      read from <filename>; use the filename '-' for STDIN
    -i <filename>

  --output=<filename>     write to <filename>; use the filename '-' for STDOUT
    -o <filename>

  --debug=<filename>      write verbose debugging info to <filename>; use the 
    -d <filename>         filename '-' for STDERR

 exit codes:

  0    success
  1    minor issues/warnings
  2    major issues (e.g. structural problems)

";
  exit $rc;
}

my $verbose = 1;
my $help = 0;
my $keep_whitespace = 0;
my $discard_comments = 0;
my $input_file = '-';
my $output_file = '-';
my $debug_file = '-';
my $main_rc = 0;

Getopt::Long::Configure ("bundling");
GetOptions(
    'v+' => \$verbose,
    'verbose+' => \$verbose,
    'q' => sub { $verbose = 0 },
    'quiet' => sub { $verbose = 0 },
    'h' => \$help,
    'help' => \$help,
    'w' => \$keep_whitespace,
    'whitespace' => \$keep_whitespace,
    'c' => \$discard_comments,
    'no-comments' => \$discard_comments,
    'i=s' => \$input_file,
    'input=s' => \$input_file,
    'o=s' => \$output_file,
    'output=s' => \$output_file,
    'd=s' => \$debug_file,
    'debug=s' => \$debug_file,
  );
usage(0) if $help;

my $INPUT_FH = *STDIN;
my $OUTPUT_FH = *STDOUT;
my $DEBUG_FH = *STDERR;

if ( $input_file && $input_file ne '-' ) {
  open($INPUT_FH, "<", $input_file) or die "ERROR: unable to open $input_file for reading: $!";
}
if ( $output_file && $output_file ne '-' ) {
  open($OUTPUT_FH, ">", $output_file) or die "ERROR: unable to open $output_file for writing: $!";
}
if ( $debug_file && $debug_file ne '-' ) {
  open($DEBUG_FH, ">", $debug_file) or die "ERROR: unable to open $debug_file for writing: $!";
}

#
# @function comment_node({str1 {, str2, ...}})
#
# Create a verbatim config node containing a comment.  If no strings are
# passed, a standard "htaccess-convert did this" comment is produced.  Otherwise,
# each string argument to the function is appended with a leading "## " prefix.
# For this reason, none of the argument strings should contain newlines.
#
sub comment_node
{
	my %node = ( 'type' => 'verbatim' );
	my $comment = '##';

	if ( scalar(@_) <= 0 ) {
		$comment = "##\n## Added by htaccess-convert\n##";
	} else {
		foreach my $line (@_) {
			$comment = $comment . "\n## " . $line;
		}
		$comment = $comment . "\n##" if ( $comment ne '##' );
	}
	$node{'value'} = $comment;
	return \%node;
}

#
# @function is_valid_host($host)
#
# Returns non-zero if the single string argument appears to be a DNS name or an
# IPv4 address, CIDR, or address/netmask combination.  Otherwise, returns zero.
#
sub is_valid_host
{
  my ($host) = @_;

  if ( $host =~ m/^([0-9]+\.){0,3}([0-9]+)?(\/((([0-9]+\.){0,3}([0-9]+)?)|([0-9]+)))?$/ ) {
    # Valid IPv4 address/network/CIDR
    return 1;
  }
  if ( $host =~ m/([a-z0-9_-]+\.)*[a-z0-9]+$/i ) {
    # Looks like a DNS name
    return 1;
  }
  return 0;
}

#
# @function hash_of_all_methods_except({method1 {, method2, ..}})
#
# Given an array of HTTP methods (all caps) passed to this function, the return
# value is a hash containing all mandatory methods that were NOT mentioned.
#
sub hash_of_all_methods_except
{
	my (@methods) = @_;
	my $method;
	my %list = map({ $_ => 1 } @mandatory_methods);

	foreach $method (@methods) {
		delete $list{$method} if ( exists $list{$method} );
	}
	return %list;
}

#
# @function fixup_limit_directives($directives)
#
# Attempt to locate and remove/replace/augment any <limit> directives that
# are present in the array of configuration directives referenced by $directives.
#
# Most notably, the appearance of a lone <limit GET> block is assumed to NOT be
# the actual intent (but instead, adherence to bad documentation) and is replaced by
# the child directives present within the <limit GET> block.
#
# Otherwise, any mandatory directives NOT covered by <limit> and <limitexcept>
# directives produce an added <limit> block that denies requests that use those
# methods.
#
sub fixup_limit_directives
{
	my ($directives) = @_;
	my $directive;
	my %methods_seen;

	# We expect an array:
	return $directives if ( reftype($directives) ne 'ARRAY' );

  printf $DEBUG_FH "INFO: enter fixup_limit_directives\n" if ($verbose >= 2);

	# Check for a <limit GET> container in the current list level:
	foreach $directive (@$directives) {
    if ( reftype($directive) eq 'HASH' ) {
    	if ( $directive->{'type'} eq 'limit-method' ) {
        my $methods = $directive->{'methods'};

        # Add the methods covered by this directive:
        if ( ! $directive->{'negate'} ) {
	        %methods_seen = (%methods_seen, map({ $_ => 1 } @$methods));
  			} else {
  				%methods_seen = (%methods_seen, hash_of_all_methods_except(@$methods));
     		}
      }
      elsif ( exists $directive->{'children'} ) {
        printf $DEBUG_FH "INFO: calling fixup_limit_directives on %s children\n", $directive->{'type'} if ($verbose >= 2);
        # Check at the next level down:
        $directive->{'children'} = fixup_limit_directives($directive->{'children'});
      }
    }
	}

	# Is it JUST the GET method?
	my $how_many_methods = scalar(keys %methods_seen);

	if ( $how_many_methods == 1 && exists $methods_seen{'GET'} ) {
		#
		# Remove the <limit GET> block and replace with the directives that were
		# inside that block.
		#
		my @new_list;

		foreach $directive (@$directives) {
			my $was_handled = 0;

			if ( reftype($directive) eq 'HASH' ) {
				if ( $directive->{'type'} eq 'limit-method' ) {
					push(@new_list, comment_node('htaccess-convert removed unnecessary <limit GET> block')) if (! $discard_comments);

					# Loop over the child directives:
					foreach $directive (@{$directive->{'children'}}) {
						push(@new_list, $directive);
					}
					$was_handled = 1;
				}
			}
			if ( ! $was_handled ) {
				push(@new_list, $directive);
			}
		}
		$directives = \@new_list;
	} elsif ( $how_many_methods > 1 ) {
		#
		# Check for any unhandled mandatory methods and add <limit> block to
		# cover them if necessary:
		#
		my %need_methods = map({ $_ => 1} @mandatory_methods);

		foreach my $method (keys %methods_seen) {
			if ( exists $need_methods{$method} ) {
				delete $need_methods{$method};
			}
		}
		if ( scalar(keys %need_methods) > 0 ) {
			my %deny_all = ( 'type' => 'require', 'negate' => 0, 'subtype' => 'all denied' );
			my @children = (\%deny_all);
			my @methods = keys %need_methods;
			my %limit = ( 'type' => 'limit-method', 'negate' => 0, 'methods' => \@methods, 'children' => \@children );
			push(@$directives, comment_node('Added by htaccess-convert', 'Augments the other method-based <limit> blocks already present')) if (! $discard_comments);
			push(@$directives, \%limit);
		}
	}
  printf $DEBUG_FH "INFO: exit fixup_limit_directives\n" if ($verbose >= 2);
	return $directives;
}

#
# @function parse_htaccess($block_name, $verbatim)
#
# Parse htaccess directives, adding them to an array to be returned by
# reference to the caller.
#
# On recursive calls, $block_name refers to the directive that triggered
# the recursion (e.g. "limit" or "limitexcept").
#
# If $verbatim is non-zero, this function attempts to do no analysis of
# the lines read.  Rather, it wraps them in "verbatim" config nodes to be
# output as-is.
#
# This function does some alteration of the directives itself:  converting
# old-style Allow and Deny directives, removing directives that are no
# longer necessary, etc.
#
sub parse_htaccess
{
  my ($block_name, $verbatim) = @_;
  my @config;

  print $DEBUG_FH "INFO: enter parse_htaccess($block_name)\n" if ($verbose >= 2);

  while ( <> ) {
    my $line = $_;

    if ( /^\s*#/ ) {
      # Comment lines can stay?
      if ( ! $discard_comments ) {
        $line =~ s/^\s+|\s+$//g;
        my %directive = ( 'type' => 'verbatim', 'value' => $line );
        push(@config, \%directive);
      }
      next;
    }
    if ( /^\s*$/ ) {
      # Drop blank lines?
      if ( $keep_whitespace ) {
        chomp($line);
        my %directive = ( 'type' => 'verbatim', 'value' => $line );
        push(@config, \%directive);
      }
      next;
    }

    # Get the first word of the line:
    my @words = split(/\s+/, $line);

    # Discard any blank leading words:
    while ( $#words >= 0 && ($words[0] =~ /^\s*$/) ) { shift @words; }

    my $firstWord = lc($words[0]);

    # Skip any ignored directives
    if ( exists $ignore{$firstWord} ) {
      next;
    }

    # We'll later check was_handled to wrap anything not handled
    # with a verbatim entry:
    my $was_handled = 0;
    if ( ! $verbatim ) {
      $was_handled = 1;
##
## <Limit>
##
      if ( $firstWord eq '<limit' ) {
        if ( $line =~ m/<limit\s+(.*)\s*>/i ) {
          my @methods = split(/\s+/, uc($1));
          my %directive = ( 'type' => 'limit-method', 'negate' => 0, 'methods' => \@methods );
          my $sublist = parse_htaccess('limit', 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@config, \%directive);
        } else {
          print $DEBUG_FH "WARNING:  empty list in <limit> block\n";
          $main_rc = 1;
        }
      }
##
## <LimitExcept>
##
      elsif ( $firstWord eq '<limitexcept' ) {
        if ( $line =~ m/<limitexcept\s+(.*)\s*>/i ) {
          my @methods = split(/\s+/, uc($1));
          my %directive = ( 'type' => 'limit-method', 'negate' => 1, 'methods' => \@methods );
          my $sublist = parse_htaccess('limitexcept', 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@config, \%directive);
        } else {
          print $DEBUG_FH "WARNING:  empty list in <limitexcept> block\n";
          $main_rc = 1;
        }
      }
##
## </LimitExcept>
##
      elsif ( $firstWord =~ /^<\/limitexcept/ ) {
        # Ensure that we were opened by <Limit>
        if ( $block_name ne 'limitexcept' ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$block_name> block\n";
          $main_rc = 2;
        }
        # Exit the loop and return
        last;
      }
##
## </Limit>  (keep this after </limitexcept> because it would match that, too!)
##
      elsif ( $firstWord =~ /^<\/limit/ ) {
        # Ensure that we were opened by <Limit>
        if ( $block_name ne 'limit' ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$block_name> block\n";
          $main_rc = 2;
        }
        # Exit the loop and return
        last;
      }
##
## <IfDefine, <IfModule, <IfVersion
##
      elsif ( $firstWord =~ /^<(if(define|module|version))/ ) {
        my $variant = $1;
        my $subtype = $2;

        if ( $line =~ m/<(if(define|module|version))\s+(.*)\s*>/i ) {
          my %directive = ( 'type' => 'conditional-block', 'subtype' => $subtype, 'argument' => $3 );
          my $sublist = parse_htaccess($variant, 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@config, \%directive);
        } else {
          print $DEBUG_FH "WARNING:  empty argument list in <$variant> block\n";
          $main_rc = 1;
        }
      }
##
## </IfDefine, </IfModule, </IfVersion
##
      elsif ( $firstWord =~ /^<\/(if(define|module|version))/ ) {
        # Ensure that we were opened by the same directive
        if ( $block_name ne $1 ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$block_name> block\n";
          $main_rc = 2;
        }
        # Exit the loop and return
        last;
      }
##
## <Files, <FilesMatch
##
      elsif ( $firstWord =~ /^<(files(match)?)/ ) {
        my $variant = $1;
        my $subtype = $2;

        if ( $line =~ m/<(files(match)?)\s+(.*)\s*>/i ) {
          my %directive = ( 'type' => 'file-block', 'subtype' => $subtype, 'argument' => $3 );
          my $sublist = parse_htaccess($variant, 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@config, \%directive);
        } else {
          print $DEBUG_FH "WARNING:  empty argument list in <$variant> block\n";
          $main_rc = 1;
        }
      }
##
## </Files, </FilesMatch
##
      elsif ( $firstWord =~ /^<\/(files(match))?/ ) {
        # Ensure that we were opened by the same directive
        if ( $block_name ne $1 ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$block_name> block\n";
          $main_rc = 2;
        }
        # Exit the loop and return
        last;
      }
##
## Allow
##
      elsif ( $firstWord eq 'allow' ) {
        # Loop over words -- they should be hostnames/IPs:
        my @hosts;
        my $ignore = 0;
        foreach my $word (@words) {
          if ( $word =~ m/^(allow|from)$/i ) {
            next;
          }
          elsif ( $word =~ m/^all$/i ) {
            @hosts = ();
            my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => 'all granted' );
            push(@config, \%directive);
            $ignore = 1;
            last;
          }
          elsif ( is_valid_host($word) ) {
            push(@hosts, $word);
          } else {
            print $DEBUG_FH "WARNING:  unknown Allow directive: '$word'\n" if $verbose;
            $main_rc = 1;
          }
        }
        if ( $#hosts >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => 'ip', 'values' => \@hosts );
          push(@config, \%directive);
        } elsif ( ! $ignore ) {
          print $DEBUG_FH "WARNING:  empty Allow directive\n" if $verbose;
          $main_rc = 1;
        }
      }
##
## Deny
##
      elsif ( $firstWord eq 'deny' ) {
        # Loop over words -- they should be hostnames/IPs:
        my @hosts;
        my $ignore = 0;
        foreach my $word (@words) {
          if ( $word =~ m/^(deny|from)$/i ) {
            next;
          }
          elsif ( $word =~ m/^all$/i ) {
            @hosts = ();
            my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => 'all denied' );
            push(@config, \%directive);
            $ignore = 1;
            last;
          }
          elsif ( is_valid_host($word) ) {
            push(@hosts, $word);
          } else {
            print $DEBUG_FH "WARNING:  unknown Deny directive: '$word'\n" if $verbose;
            $main_rc = 1;
          }
        }
        if ( $#hosts >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 1, 'subtype' => 'ip', 'values' => \@hosts );
          push(@config, \%directive);
        } elsif ( ! $ignore ) {
          print $DEBUG_FH "WARNING:  empty Deny directive\n" if $verbose;
          $main_rc = 1;
        }
      }
##
## Require
##
      elsif ( $firstWord eq 'require' ) {
        my @entities = @words;
        shift @entities;

        my $variant = lc(shift @entities);
        my @values;

        if ( $variant eq 'valid_user' ) {
          # Correct misspellings:
          $variant = 'valid-user';
        }

        if ( $variant ne 'valid-user' ) {
          if ( $variant =~ /^(ldap-(group|user|attribute)|group|user)$/ ) {
            foreach my $entity (@entities) {
              if ( $variant eq 'ldap-group' || $variant eq 'ldap-user' || $variant eq 'ldap-attribute' || $variant eq 'user' ) {
                push(@values, $entity);
              }
              elsif ( $variant eq 'group' ) {
                push(@values, "cn=" . $entity . ",ou=Groups,o=udel.edu");
              }
            }
            if ( $variant eq 'group' ) {
              # group has been morphed to ldap-group now:
              $variant = 'ldap-group';
            }
          } else {
            print $DEBUG_FH "WARNING:  unknown Require sub-type: $variant\n" if $verbose;
            $main_rc = 1;
          }
        }
        if ( $#values >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => $variant, 'values' => \@values );
          push(@config, \%directive);
        }
      }
##
## Order
##
      elsif ( $firstWord eq 'order' ) {
        if ( $line =~ m/order\s+allow\s*,\s*deny/i ) {
          my %directive = ( 'type' => 'order', 'order' => 'AD' );
          push(@config, \%directive);
        }
        elsif ( $line =~ m/order\s+deny\s*,\s*allow/i ) {
          my %directive = ( 'type' => 'order', 'order' => 'DA' );
          push(@config, \%directive);
        }
      }
##
## Satisfy
##
      elsif ( $firstWord eq 'satisfy' ) {
        #
        # Is it an "any" or an "all" directive:
        #
        my $is_all = 1;
        foreach my $word (@words) {
          if ( $word =~ /^all$/i ) {
            $is_all = 1;
            last;
          }
          elsif ( $word =~ /^any$/i ) {
            $is_all = 0;
            last;
          }
        }
        if ( $is_all ) {
          my %directive = ( 'type' => 'satisfy', 'subtype' => 'all' );
          push(@config, \%directive);
        } else {
          my %directive = ( 'type' => 'satisfy', 'subtype' => 'any' );
          push(@config, \%directive);
        }
      }
##
## <RequireAny>, <RequireAll>, <RequireNone>
##
      elsif ( $firstWord =~ /^<(require(any|all|none))/ ) {
        my %directive = ( 'type' => $1 );
        my $sublist = parse_htaccess($1,1 );
        if ( $sublist && (scalar @$sublist >= 0) ) {
          $directive{'children'} = $sublist;
        }
        push(@config, \%directive);
      }
      else {
        $was_handled = 0;
      }
    }
    elsif ( $firstWord =~ /^<\/$block_name/ ) {
      last;
    }
##
## Anything else
##
    if ( ! $was_handled ) {
      $line =~ s/^\s+|\s+$//g;
      my %directive = ( 'type' => 'verbatim', 'value' => $line );
      push(@config, \%directive);
    }
  }

  print $DEBUG_FH "INFO: exit parse_htaccess($block_name)\n" if ($verbose >= 2);
  return \@config;
}

#
# @function index($indent)
#
# Write $indent spaces to our output channel.
#
sub indent
{
  my ($indent) = @_;

  print $OUTPUT_FH " " x $indent;
}

#
# @function unparse_htaccess($directives, $indent)
#
# Given a refrence to an array of configuration directives (as produced by the
# parse_htaccess() function) serialize the directives to the program's output
# channel.
#
# Some transformations will be effected herein:  wrapping authorization directives
# with <Require*> blocks to match a Satisfy directive, for example.
#
sub unparse_htaccess
{
  my ($directives, $indent) = @_;
  my $satisfy = 0;
  my $blank = 0;
  my $directive;

  print $DEBUG_FH "INFO: enter unparse_htaccess($indent)\n" if ($verbose >= 2);

  #
  # Determine if there was a Satisfy directive present; if so, add the
  # appropriate authz grouping tag around what follows:
  #
  foreach $directive (@$directives) {
    if ( reftype($directive) eq 'HASH' && $directive->{'type'} eq 'satisfy' ) {
      $satisfy = $directive->{'subtype'};
    }
  }
  if ( $satisfy ) {
    my $has_requires = 0;

    # See if there are any require directives present at this level; if not, then
    # we won't be wrapping anything anyway:
    foreach $directive (@$directives) {
      if ( reftype($directive) eq 'HASH' && $directive->{'type'} =~ m/^require(all|any|none)?$/ ) {
        $has_requires = 1;
        last;
      }
    }
    if ( $has_requires ) {
      my @remainder;

      indent($indent);
      printf $OUTPUT_FH "<Require%s>\n", ucfirst($satisfy);
      $indent = $indent + 2;

      # We only handle the Require directives present at this level:
      foreach $directive (@$directives) {
        if ( reftype($directive) eq 'ARRAY' ) {
          push(@remainder, $directive);
        }
        elsif ( reftype($directive) eq 'HASH' ) {
##
## require
##
          if ( $directive->{'type'} eq 'require' ) {
            indent($indent);
            printf $OUTPUT_FH "Require ";
            printf $OUTPUT_FH "not " if ( $directive->{'negate'} );
            if ( exists $directive->{'values'} ) {
              my $entities = $directive->{'values'};
              printf $OUTPUT_FH "%s %s\n", $directive->{'subtype'}, join(' ', @$entities);
            } else {
              printf $OUTPUT_FH "%s\n", $directive->{'subtype'};
            }
          }
##
## requireany, requireall, requirenone
##
          elsif ( $directive->{'type'} =~ m/^require(all|any|none)$/ ) {
            indent($indent);
            printf $OUTPUT_FH "<%s>\n",  $require_group_pretty{$directive->{'type'}};
            if ( exists $directive->{'children'} ) {
              unparse_htaccess($directive->{'children'}, $indent + 2);
            }
            indent($indent);
            printf $OUTPUT_FH "</%s>\n", $require_group_pretty{$directive->{'type'}};
          }
          else {
            push(@remainder, $directive);
          }
        }
      }
      # Anything that wasn't handled by this loop, hand to the default loop (next):
      $directives = \@remainder;
    } else {
      $satisfy = 0;
    }
  }

  foreach $directive (@$directives) {
    if ( reftype($directive) eq 'ARRAY') {
      unparse_htaccess($directive, $indent + 2);
    }
    elsif ( reftype($directive) eq 'HASH' ) {
##
## verbatim line
##
      if ( $directive->{'type'} eq 'verbatim' ) {
        indent($indent);
        printf $OUTPUT_FH "%s\n", $directive->{'value'};
      }
##
## requireany, requireall, requirenone
##
      elsif ( $directive->{'type'} =~ m/^require(all|any|none)$/ ) {
        indent($indent);
        printf $OUTPUT_FH "<%s>\n",  $require_group_pretty{$directive->{'type'}};
        if ( exists $directive->{'children'} ) {
          unparse_htaccess($directive->{'children'}, $indent + 2);
        }
        indent($indent);
        printf $OUTPUT_FH "</%s>\n", $require_group_pretty{$directive->{'type'}};
      }
##
## <limit>, <limitexcept>
##
      elsif ( $directive->{'type'} eq 'limit-method' ) {
        my $methods = $directive->{'methods'};
        indent($indent);
        printf $OUTPUT_FH "<Limit%s %s>\n", ($directive->{'negate'} ? 'Except' : ''), join(' ', @$methods);
        if ( exists $directive->{'children'} ) {
          unparse_htaccess($directive->{'children'}, $indent + 2);
        }
        indent($indent);
        printf $OUTPUT_FH "</Limit%s>\n", ($directive->{'negate'} ? 'Except' : '');
      }
##
## <ifdefine>, <ifmodule>, <ifversion>
##
      elsif ( $directive->{'type'} eq 'conditional-block' ) {
        my $argument = $directive->{'argument'};
        indent($indent);
        printf $OUTPUT_FH "<If%s %s>\n", ucfirst($directive->{'subtype'}), $argument;
        if ( exists $directive->{'children'} ) {
          unparse_htaccess($directive->{'children'}, $indent + 2);
        }
        indent($indent);
        printf $OUTPUT_FH "</If%s>\n", ucfirst($directive->{'subtype'});
      }
##
## <files>, <filesmatch>
##
      elsif ( $directive->{'type'} eq 'file-block' ) {
        my $argument = $directive->{'argument'};
        indent($indent);
        printf $OUTPUT_FH "<Files%s %s>\n", ucfirst($directive->{'subtype'}), $argument;
        if ( exists $directive->{'children'} ) {
          unparse_htaccess($directive->{'children'}, $indent + 2);
        }
        indent($indent);
        printf $OUTPUT_FH "</Files%s>\n", ucfirst($directive->{'subtype'});
      }
##
## require
##
      elsif ( $directive->{'type'} eq 'require' ) {
        indent($indent);
        printf $OUTPUT_FH "Require ";
        printf $OUTPUT_FH "not " if ( $directive->{'negate'} );
        if ( exists $directive->{'values'} ) {
          my $entities = $directive->{'values'};
          printf $OUTPUT_FH "%s %s\n", $directive->{'subtype'}, join(' ', @$entities);
        } else {
          printf $OUTPUT_FH "%s\n", $directive->{'subtype'};
        }
      }
    }
  }
  if ( $satisfy ) {
    # We emitted a <Require*> section around this content, so close it now:
    $indent = $indent - 2;
    indent($indent);
    printf $OUTPUT_FH "</Require%s>\n", ucfirst($satisfy);
  }

  print $DEBUG_FH "INFO: exit unparse_htaccess($indent)\n" if ($verbose >= 2);
}

#
# Here we get to the main program...
#
print $DEBUG_FH "INFO: parsing htaccess file\n" if ($verbose >= 2);
my $config = parse_htaccess('', 0);

# If we got a non-trivial config, then attempt to fix it and serialize it back to
# our output channel:
if ( $config && (scalar @$config >= 0) ) {
  print $DEBUG_FH "INFO: performing <limit> fixups on htaccess config\n" if ($verbose >= 2);
	$config = fixup_limit_directives($config);
  if ( $verbose > 2 ) {
    print $DEBUG_FH "INFO: parsed htaccess file representation:  ";
    print $DEBUG_FH Dumper $config;
  }
  print $DEBUG_FH "INFO: serializing htaccess config\n" if ($verbose >= 2);
  unparse_htaccess($config, 0);
} elsif ($verbose >= 2) {
  print $DEBUG_FH "INFO: empty htaccess configuration\n";
}

exit $main_rc;
