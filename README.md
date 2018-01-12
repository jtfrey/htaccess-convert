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
