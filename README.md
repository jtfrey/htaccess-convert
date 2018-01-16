# htaccess-convert
Perl utility to update UD legacy web server htaccess files to Apache 2.4.  Rewrites "require group" directives to use LDAP authorization.  Automatically generates <RequireAny> or <RequireAll> groupings based on the Satisfy keyword.

```
usage: ./htaccess-convert.pl {options}

  --verbose, -v           increase level of verbosity
  --quiet, -q             no verbosity
  --help, -h              display this help screen

  --test-only, -t         tests the input file to determine if an update is
                          necessary to remain compatible; exit code of zero if
                          no update necessary, non-zero otherwise

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

```

For example, consider the following htaccess file:

```
$ cat examples/htaccess.txt
#
# Comments are allowed
#
AuthType Basic
<limit GET>
  order deny,allow
  allow from 128.175 boffo.net
  deny from all
  require group 4000
  Satisfy any
</limit>
<limitexcept GET >
  allow from
  deny from all
  satisfy all
</limitexcept>
AddType application/vnd.ms-excel   xls
AddType application/vnd.ms-powerpoint   ppt
AddType application/msword   doc
Satisfy any
```

Running this through the converter yields:

```
$ ./htaccess-convert.pl --input=examples/htaccess.txt --output=htaccess-conv.txt -v
INFO: parsing htaccess file
INFO: enter parse_htaccess()
INFO: enter parse_htaccess(limit)
INFO: exit parse_htaccess(limit)
INFO: enter parse_htaccess(limitexcept)
WARNING:  empty Allow directive
INFO: exit parse_htaccess(limitexcept)
INFO: enter parse_htaccess(ifmodule)
INFO: enter parse_htaccess(filesmatch)
INFO: exit parse_htaccess(filesmatch)
INFO: exit parse_htaccess(ifmodule)
INFO: exit parse_htaccess()
INFO: performing <limit> fixups on htaccess config
INFO: enter fixup_limit_directives
INFO: calling fixup_limit_directives on conditional-block children
INFO: enter fixup_limit_directives
INFO: calling fixup_limit_directives on file-block children
INFO: enter fixup_limit_directives
INFO: exit fixup_limit_directives
INFO: exit fixup_limit_directives
INFO: exit fixup_limit_directives
INFO: serializing htaccess config
INFO: enter unparse_htaccess(0)
INFO: enter unparse_htaccess(2)
INFO: exit unparse_htaccess(2)
INFO: enter unparse_htaccess(2)
INFO: exit unparse_htaccess(2)
INFO: enter unparse_htaccess(2)
INFO: enter unparse_htaccess(4)
INFO: exit unparse_htaccess(4)
INFO: exit unparse_htaccess(2)
INFO: exit unparse_htaccess(0)

$ cat htaccess-conv.txt
#
# Comments are allowed
#
<Limit GET>
  <RequireAny>
    Require ip 128.175 boffo.net
    Require all denied
    Require ldap-group cn=4000,ou=Groups,o=udel.edu
  </RequireAny>
</Limit>
<LimitExcept GET>
  <RequireAll>
    Require all denied
  </RequireAll>
</LimitExcept>
AddType application/vnd.ms-excel   xls
AddType application/vnd.ms-powerpoint   ppt
AddType application/msword   doc
```

A subsequent test of the converted form shows that it's now okay:

```
$ ./htaccess-convert.pl --test-only --input=htaccess-conv.txt
INFO: htaccess config does not require updating

$ echo $?
0
```

The converter also attempts to detect the erroneously-documented use of `<Limit GET>` and remove it:

```
$ cat examples/htaccess-simple.txt
#
# Comments are allowed
#
AuthType Basic
AuthName "Auth is fun"
AuthBasicProvider ldap
<limit GET>
  require group 4000
</limit>

$ ./htaccess-convert.pl --test-only --input=examples/htaccess-simple.txt
INFO: htaccess config requires updating

$ ./htaccess-convert.pl --input=examples/htaccess-simple.txt
#
# Comments are allowed
#
##
## htaccess-convert removed unnecessary <limit GET> block
##
Require ldap-group cn=4000,ou=Groups,o=udel.edu
```

If multiple `<Limit>` blocks are present, then the converter ensures that *at least* the GET and POST methods are covered:

```
$ cat examples/htaccess-limits.txt
<limit GET>
  order deny,allow
  allow from 128.175 boffo.net
  deny from all
  require group 4000
  Satisfy any
</limit>
<limit PUT>
  allow from 128.4
  deny from all
  satisfy all
</LIMIT>

$ ./htaccess-convert.pl < examples/htaccess-limits.txt
<Limit GET>
  <RequireAny>
    Require ip 128.175 boffo.net
    Require all denied
    Require ldap-group cn=4000,ou=Groups,o=udel.edu
  </RequireAny>
</Limit>
<Limit PUT>
  <RequireAll>
    Require ip 128.4
    Require all denied
  </RequireAll>
</Limit>
##
## Added by htaccess-convert
## Augments the other method-based <limit> blocks already present
##
<Limit POST>
  Require all denied
</Limit>

```

