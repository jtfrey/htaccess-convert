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

sub usage
{
  my( $rc ) = @_;
  print "
usage: $0 {options}

  --verbose, -v           increase level of verbosity
  --quiet, -q             no verbosity
  --help, -h              display this help screen

  --input=<filename>      read from <filename>; use the
    -i <filename>         filename '-' for STDIN

  --output=<filename>     write to <filename>; use the
    -o <filename>         filename '-' for STDOUT

  --debug=<filename>      write verbose debugging info to
    -d <filename>         <filename>; use the filename '-'
                          for STDERR

";
  exit $rc;
}

my $verbose = 1;
my $help = 0;
my $input_file = '-';
my $output_file = '-';
my $debug_file = '-';

Getopt::Long::Configure ("bundling");
GetOptions(
    'v+' => \$verbose,
    'verbose+' => \$verbose,
    'q' => sub { $verbose = 0 },
    'quiet' => sub { $verbose = 0 },
    'h' => \$help,
    'help' => \$help,
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

sub require_group_pretty
{
  my ($tag) = @_;

  return 'RequireAll' if ( $tag eq 'requireall' );
  return 'RequireAny' if ( $tag eq 'requireany' );
  return 'RequireNone' if ( $tag eq 'requirenone' );
  return '';
}

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

sub parse_htaccess
{
  my ($openTag, $verbatim) = @_;
  my @require;

  print $DEBUG_FH "INFO: enter parse_htaccess($openTag)\n" if ($verbose >= 2);

  while ( <> ) {
    my $line = $_;

    if ( /^\s*#/ ) {
      # Comment lines can stay...
      $line =~ s/^\s+|\s+$//g;
      my %directive = ( 'type' => 'verbatim', 'value' => $line );
      push(@require, \%directive);
      next;
    }
    if ( /^\s*$/ ) {
      # Drop blank lines
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
          my @methods = split(/\s+/, $1);
          my %directive = ( 'type' => 'limit-method', 'negate' => 0, 'methods' => \@methods );
          my $sublist = parse_htaccess('limit', 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@require, \%directive);
        }
      }
##
## <LimitExcept>
##
      elsif ( $firstWord eq '<limitexcept' ) {
        if ( $line =~ m/<limitexcept\s+(.*)\s*>/i ) {
          my @methods = split(/\s+/, $1);
          my %directive = ( 'type' => 'limit-method', 'negate' => 1, 'methods' => \@methods );
          my $sublist = parse_htaccess('limitexcept', 0);
          if ( $sublist && (scalar @$sublist >= 0) ) {
            $directive{'children'} = $sublist;
          }
          push(@require, \%directive);
        }
      }
##
## </LimitExcept>
##
      elsif ( $firstWord =~ /^<\/limitexcept/ ) {
        # Ensure that we were opened by <Limit>
        if ( $openTag ne 'limitexcept' ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$openTag> block\n";
        }
        # Exit the loop and return
        last;
      }
##
## </Limit>
##
      elsif ( $firstWord =~ /^<\/limit/ ) {
        # Ensure that we were opened by <Limit>
        if ( $openTag ne 'limit' ) {
          print $DEBUG_FH "ERROR:  $firstWord directive encountered inside a <$openTag> block\n";
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
            push(@require, \%directive);
            $ignore = 1;
            last;
          }
          elsif ( is_valid_host($word) ) {
            push(@hosts, $word);
          } else {
            print $DEBUG_FH "WARNING:  unknown Allow directive: '$word'\n" if $verbose;
          }
        }
        if ( $#hosts >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => 'ip', 'values' => \@hosts );
          push(@require, \%directive);
        } elsif ( ! $ignore ) {
          print $DEBUG_FH "WARNING:  empty Allow directive\n" if $verbose;
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
            push(@require, \%directive);
            $ignore = 1;
            last;
          }
          elsif ( is_valid_host($word) ) {
            push(@hosts, $word);
          } else {
            print $DEBUG_FH "WARNING:  unknown Deny directive: '$word'\n" if $verbose;
          }
        }
        if ( $#hosts >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 1, 'subtype' => 'ip', 'values' => \@hosts );
          push(@require, \%directive);
        } elsif ( ! $ignore ) {
          print $DEBUG_FH "WARNING:  empty Deny directive\n" if $verbose;
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
          }
        }
        if ( $#values >= 0 ) {
          my %directive = ( 'type' => 'require', 'negate' => 0, 'subtype' => $variant, 'values' => \@values );
          push(@require, \%directive);
        }
      }
##
## Order
##
      elsif ( $firstWord eq 'order' ) {
        if ( $line =~ m/order\s+allow\s*,\s*deny/i ) {
          my %directive = ( 'type' => 'order', 'order' => 'AD' );
          push(@require, \%directive);
        }
        elsif ( $line =~ m/order\s+deny\s*,\s*allow/i ) {
          my %directive = ( 'type' => 'order', 'order' => 'DA' );
          push(@require, \%directive);
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
          push(@require, \%directive);
        } else {
          my %directive = ( 'type' => 'satisfy', 'subtype' => 'any' );
          push(@require, \%directive);
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
        push(@require, \%directive);
      }
      else {
        $was_handled = 0;
      }
    }
    elsif ( $firstWord =~ /^<\/$openTag/ ) {
      last;
    }
##
## Anything else
##
    if ( ! $was_handled ) {
      $line =~ s/^\s+|\s+$//g;
      my %directive = ( 'type' => 'verbatim', 'value' => $line );
      push(@require, \%directive);
    }
  }

  print $DEBUG_FH "INFO: exit parse_htaccess($openTag)\n" if ($verbose >= 2);
  return \@require;
}

sub indent
{
  my ($indent) = @_;

  print $OUTPUT_FH " " x $indent;
}

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
      if ( reftype($directive) eq 'HASH' && $directive->{'type'} eq 'require' && $directive->{'type'} =~ m/^require(all|any|none)$/ ) {
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
            printf $OUTPUT_FH "<%s>\n",  require_group_pretty($directive->{'type'});
            if ( exists $directive->{'children'} ) {
              unparse_htaccess($directive->{'children'}, $indent + 2);
            }
            indent($indent);
            printf $OUTPUT_FH "</%s>\n", require_group_pretty($directive->{'type'});
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
        printf $OUTPUT_FH "<%s>\n",  require_group_pretty($directive->{'type'});
        if ( exists $directive->{'children'} ) {
          unparse_htaccess($directive->{'children'}, $indent + 2);
        }
        indent($indent);
        printf $OUTPUT_FH "</%s>\n", require_group_pretty($directive->{'type'});
      }
##
## limit, limitexcept
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

my $requires = parse_htaccess('', 0);

if ( $requires && (scalar @$requires >= 0) ) {
  if ( $verbose > 2 ) {
    print $DEBUG_FH "INFO: parsed htaccess file representation:  ";
    print $DEBUG_FH Dumper $requires;
  }
  unparse_htaccess($requires, 0);
}
