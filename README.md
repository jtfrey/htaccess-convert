# htaccess-convert

This project represents an effort to update UD legacy web server htaccess files to Apache 2.4 in an automated, batch fashion.  In particular, we need to rewrite "require group" directives to use LDAP DN patterns.  We need to automatically generate <RequireAny> or <RequireAll> groupings based on the Satisfy keyword.  We need to get rid of `<Limit GET>` wrappers that have been in our documentation for over a decade and shouldn't have been.

## htaccess-convert.pl

A Perl script that parses an htaccess file and can determine whether or not it needs any updates to be compatible with the Apache 2.4 server farm.  The necessary changes can also be effected by the script.

```
usage: ./htaccess-convert.pl {options}

  --verbose, -v           increase level of verbosity
  --quiet, -q             no verbosity
  --help, -h              display this help screen

  --test-only, -t         tests the input file to determine if an update is
                          necessary to remain compatible; exit code of zero if
                          no update necessary, non-zero otherwise
    --invert-exit, -x     inverse the exit codes:  zero if update necessary,
                          non-zero otherwise

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

## htaccess-convert-all.sh

A Bash script that walks a directory tree looking for `.htaccess` files and uses `htaccess-convert.pl` to determine whether or not they need to be updated.  Given the list of files, the script can create a shadow directory tree and populate it with the updated files generated by a second invocation of `htaccess-convert.pl`.

```
usage:

  ./htaccess-convert-all.sh {options} {<source dir>} {<shadow dir>}

 options:

  -v/--verbose          display addition information to STDERR
  -h/--help             display this information and exit

  -k/--keep-filelist    retain the list of files if -l/--filelist is also
                        used
  -o/--list-only        generate the list of .htaccess files needing update
                        but do not perform the updates; if -l/--filelist is
                        not provided, the list will be written to STDOUT
  -m/--no-mkdir         do not create any directories in the shadow tree
  -a/--no-access-copy   do not copy all file/directory access control pieces
                        (mode, ownership, ACLs, etc.); note that this is
                        always the case when this program is NOT run as root

  -s/--srcdir <path>    search for .htaccess files in the directory tree
  --srcdir=<path>       rooted at <path>

  -d/--dstdir <path>    write converted .htaccess files to the directory
  --dstdir=<path>       tree rooted at <path>; directories will be created
                        to shadow the hierarchy of the source tree (unless
                        -m/--no-mkdir is used)

  -l/--filelist <path>  write the list of .htaccess files needing update to
  --filelist=<path>     the given <path>; if not provided (and -l/--list-only
                        is not used) mktemp will be used to create a file in
                        /var/folders/b9/1mzp0hxs2g99741jsl5618t00000gp/T/

```

In its simplest form:

```
$ ./htaccess-convert-all.sh src dst
WARNING:  the find command exited with non-zero status: 1
WARNING:  minor issues with src/.htaccess
```

In this instance, the warning regarding the `find` command is because one subdirectory of `src` is owned by root and I don't have permission to read it.  The "minor issues" warning stems from `htaccess-convert.pl` having result code 1 when `src/.htaccess` is converted; manually running `htaccess-convert.pl` on that file would reveal the reason for the warning:

```
$ ./htaccess-convert.pl --input=src/.htaccess >/dev/null
WARNING:  empty Allow directive
```

Ideally, when used on a large document tree the script would be run as root to avoid any permissions-oriented problems.  In this case, the shadow directory tree will by default have file metadata copied from the source tree, as well:  permissions, ownership, ACLs, and extended attributes.

The `--verbose` flag is strongly recommended when working on large document trees.
