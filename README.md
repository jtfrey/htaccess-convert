# htaccess-convert
Perl utility to update UD legacy web server htaccess files to Apache 2.4.  Rewrites "require group" directives to use LDAP authorization.  Automatically generates <RequireAny> or <RequireAll> groupings based on the Satisfy keyword.

```
usage: htaccess-convert.pl {options}

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
INFO: enter parse_htaccess()
INFO: enter parse_htaccess(limit)
INFO: exit parse_htaccess(limit)
INFO: enter parse_htaccess(limitexcept)
WARNING:  empty Allow directive
INFO: exit parse_htaccess(limitexcept)
INFO: exit parse_htaccess()
INFO: enter unparse_htaccess(0)
INFO: enter unparse_htaccess(2)
INFO: exit unparse_htaccess(2)
INFO: enter unparse_htaccess(2)
INFO: exit unparse_htaccess(2)
INFO: exit unparse_htaccess(0)

$ cat htaccess-conf.txt
#
# Comments are allowed
#
<Limit GET>
  Require ip 128.175 boffo.net
  Require all denied
  Require ldap-group cn=4000,ou=Groups,o=udel.edu
</Limit>
<LimitExcept GET>
  Require all denied
</LimitExcept>
AddType application/vnd.ms-excel   xls
AddType application/vnd.ms-powerpoint   ppt
AddType application/msword   doc
```
