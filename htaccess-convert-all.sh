#!/bin/bash
#
# Uses the htaccess-convert.pl tool to create a shadow directory
# tree containing every updated .htaccess file under a given
# directory.
#

HTACCESS_CONVERT_UTIL="$(pwd)/htaccess-convert.pl"

PLATFORM="$(uname -s)"
case "$PLATFORM" in

  Linux)
    GETFACL="$(which getfattr)"
    if [ $? -ne 0 ]; then
      GETFACL=''
    fi
    GETFATTR="$(which getfattr)"
    if [ $? -ne 0 ]; then
      GETFATTR=''
    fi
    STAT_FORMAT_UG_FLAG="--format=%u:%g"
    STAT_FORMAT_PERM_FLAG="--format=%a"
    ;;

  Darwin)
    GETFACL=''
    GETFATTR=''
    STAT_FORMAT_UG_FLAG="-f%u:%g"
    STAT_FORMAT_PERM_FLAG="-f%Mp%Lp"
    ;;

  *)
    echo "ERROR:  this script is qualified to run on Mac OS X or Linux"
    exit 1
    ;;

esac

SOURCE_DIR=''
DEST_DIR=''
FILE_LIST=''
VERBOSE=0
MAKE_DIRS=1
NO_ACCESS_COPY=0
KEEP_FILE_LIST=0
LIST_ONLY=0

copy_access()
{
  local src="${SOURCE_DIR}/$1"
  local dst="${DEST_DIR}/$1"
  local rc=0

  chown $(stat ${STAT_FORMAT_UG_FLAG} "$src") "$dst" 2>/dev/null
  rc=$?
  if [ $rc -eq 0 ]; then
    chmod $(stat ${STAT_FORMAT_PERM_FLAG} "$src") "$dst" 2>/dev/null
    rc=$?
    if [ $rc -eq 0 -a -n "$GETFACL" ]; then
      local acl="$(getfacl -ns "$dst" 2>/dev/null)"
      rc=$?
      if [ $rc -eq 0 -a -n "$acl" ]; then
        printf "%s\n" "$acl" | setfacl --modify-file - "$dst"
        rc=$?
        if [ $rc -eq 0 -a -n "$GETFATTR" ]; then
          acl="$(getfattr --dump "$src" | grep -v '^#')"
          rc=$?
          if [ $rc -eq 0 -a -n "$acl" ]; then
            printf "# file: %s\n%s\n" "$dst" "$acl" | setfattr --restore=-
            rc=$?
          fi
        fi
      fi
    fi
  fi
  return $rc
}

copy_access_recursive()
{
  local rc
  local relpath="${1:-.}"
  local endpath="${2:-.}"

  copy_access "$relpath"
  rc=$?
  if [ $rc -eq 0 ]; then
    if [ "$relpath" = "$endpath" ]; then
      return 0
    fi
    relpath="$(dirname "$relpath")"
    if [ "$relpath" = "$endpath" ]; then
      return 0
    fi
    copy_access_recursive "$relpath" "$endpath"
    rc=$?
  fi
  return $rc
}

copy_htaccess()
{
  local src="${SOURCE_DIR}/$1"
  local dst="${DEST_DIR}/$1"
  local rc=1

  if [ -f "$src" ]; then
    cp -a "$src" "$dst" 2>&1
    rc=$?
  fi
  return $rc
}

create_shadow_dir()
{
  local relpath="${1:-.}"
  local dstpath="${DEST_DIR}/${relpath}"

  if [ -d "$dstpath" ]; then
    return 0
  fi
  if [ -e "$dstpath" ]; then
    echo "ERROR:  path exists but is not a directory: $dstpath"
    return 1
  fi

  debug "creating shadow directory: $dstpath"

  local extant_base="$(dirname "$relpath")"
  while [ -n "$extant_base" -a "$extant_base" != '.' -a ! -e "${DEST_DIR}/${extant_base}" ]; do
    extant_base="$(dirname "$extant_base")"
  done

  local errstr=$(mkdir -p "$dstpath" 2>&1)
  if [ $? -ne 0 ]; then
    echo "ERROR:  unable to create path: $dstpath"
    echo "        $errstr"
    return 1
  fi

  if [ $NO_ACCESS_COPY -eq 0 -a "$EUID" -eq 0 ]; then
    debug_inc_level
    debug "copying access settings from ${SOURCE_DIR}/${extant_base} through ${SOURCE_DIR}/${relpath}"
    copy_access_recursive "$relpath" "$extant_base"
    debug_dec_level
    if [ $? -ne 0 ]; then
      return 1
    fi
  fi

  return 0
}

#
##
#

DEBUG_NEST_LEVEL=0

debug_inc_level()
{
  DEBUG_NEST_LEVEL=$((DEBUG_NEST_LEVEL+1))
}

debug_dec_level()
{
  if [ $DEBUG_NEST_LEVEL -gt 0 ]; then
    DEBUG_NEST_LEVEL=$((DEBUG_NEST_LEVEL-1))
  fi
}

debug()
{
  local i

  if [ $VERBOSE -ne 0 ]; then
    while [ -n "$1" ]; do
      local s="INFO: "
      i=${DEBUG_NEST_LEVEL:-0}
      while [ $i -gt 0 ]; do
        s="${s}  "
        i=$((i-1))
      done
      s="${s}$1"
      printf "%s\n" "$s" 1>&2
      shift
    done
  fi
}

#
##
#

usage()
{
  local rc=$1

  if [ -z "$1" ]; then
    rc=0
  fi

  cat <<EOT

usage:

  $0 {options} {<source dir>} {<shadow dir>}

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
                        ${TMPDIR:-/tmp}

EOT
  exit $rc
}

#
##
#

#
# Take care of flags first:
#
while [ -n "$1" ]; do
  if [[ $1 =~ ^--? ]]; then
    case "$1" in

      -h|--help)
        usage 0
        ;;

      -v|--verbose)
        VERBOSE=1
        ;;

      -s|--srcdir)
        shift
        if [ -z "$1" ]; then
          echo "ERROR:  no directory provided for -s/--srcdir"
          exit 1
        fi
        SOURCE_DIR="$1"
        ;;

      --srcdir=*)
        if [[ $1 =~ ^--srcdir=(.*)$ ]]; then
          SOURCE_DIR="${BASH_REMATCH[1]}"
        else
          echo "ERROR:  no directory provided for --srcdir"
          exit 1
        fi
        ;;

      -d|--dstdir)
        shift
        if [ -z "$1" ]; then
          echo "ERROR:  no directory provided for -d/--dstdir"
          exit 1
        fi
        DEST_DIR="$1"
        ;;

      --dstdir=*)
        if [[ $1 =~ ^--dstdir=(.*)$ ]]; then
          DEST_DIR="${BASH_REMATCH[1]}"
        else
          echo "ERROR:  no directory provided for --dstdir"
          exit 1
        fi
        ;;

      -l|--filelist)
        shift
        if [ -z "$1" ]; then
          echo "ERROR:  no path provided for -l/--filelist"
          exit 1
        fi
        FILE_LIST="$1"
        ;;

      --filelist=*)
        if [[ $1 =~ ^--filelist=(.*)$ ]]; then
          FILE_LIST="${BASH_REMATCH[1]}"
        else
          echo "ERROR:  no path provided for --filelist"
          exit 1
        fi
        ;;

      -k|--keep-filelist)
        KEEP_FILE_LIST=1
        ;;

      -o|--list-only)
        LIST_ONLY=1
        ;;

      -m|--no-mkdir)
        MAKE_DIRS=0
        ;;

      -a|--no-access-copy)
        NO_ACCESS_COPY=1
        ;;

    esac
  else
    break
  fi
  shift
done

#
# If the base directory was not provided, then we expect if as the
# next argument:
#
if [ -z "$SOURCE_DIR" ]; then
  if [ -z "$1" ]; then
    echo "ERROR:  no source directory provided"
    exit 1
  fi
  SOURCE_DIR="$1"
  shift
fi
# Ensure the directory exists and we can read it:
if [ ! -e "$SOURCE_DIR" ]; then
  echo "ERROR:  source directory does not exist: $SOURCE_DIR"
  exit 1
fi
if [ ! -d "$SOURCE_DIR" ]; then
  echo "ERROR:  source directory path is not a directory: $SOURCE_DIR"
  exit 1
fi
if [ ! -r "$SOURCE_DIR" ]; then
  echo "ERROR:  source directory not readable: $SOURCE_DIR"
  exit 1
fi
debug "source directory ready: $SOURCE_DIR"

if [ $LIST_ONLY -eq 0 ]; then
  #
  # We do NOT support DEST_DIR being the same as SOURCE_DIR:
  #
  if [ "$DEST_DIR" = "$SOURCE_DIR" ]; then
    echo "ERROR:  shadow directory cannot be the same as the source directory"
    exit 1
  fi
  #
  # If the shadow directory was not provided, then we expect if as the
  # next argument:
  #
  if [ -z "$DEST_DIR" ]; then
    if [ -z "$1" ]; then
      echo "ERROR:  no shadow directory provided"
      exit 1
    fi
    DEST_DIR="$1"
    shift
  fi
  # Ensure the directory exists and we can write it:
  if [ ! -e "$DEST_DIR" ]; then
    if [ $MAKE_DIRS -ne 0 ]; then
      create_shadow_dir ""
      if [ $? -ne 0 ]; then
        exit 1
      fi
    else
      echo "ERROR:  shadow directory does not exist"
      exit 1
    fi
  else
    if [ ! -d "$DEST_DIR" ]; then
      echo "ERROR:  shadow directory path is not a directory: $DEST_DIR"
      exit 1
    fi
    if [ ! -w "$DEST_DIR" ]; then
      echo "ERROR:  shadow directory not writable: $DEST_DIR"
      exit 1
    fi
  fi

  # If root, copy all access:
  if [ $NO_ACCESS_COPY -eq 0 -a "$EUID" -eq 0 ]; then
    copy_access "."
    if [ $? -ne 0 ]; then
      echo "ERROR:  unable to copy access properties to $DEST_DIR"
      exit 1
    fi
  fi

  debug "shadow directory ready: $DEST_DIR"
fi

if [ $LIST_ONLY -ne 0 ]; then
  #
  # Do the 'find' across the SOURCE_DIR directory tree, looking for .htaccess files
  # that need to be updated.  In this mode, we simply dump that list to STDOUT:
  #
  debug "searching '$SOURCE_DIR' for .htaccess files needing updating"
  if [ -z "$FILE_LIST" ]; then
    find "$SOURCE_DIR" -type f -name .htaccess -exec "$HTACCESS_CONVERT_UTIL" --quiet --test-only --invert-exit --input=\{\} \; -print 2>/dev/null
    rc=$?
  else
    find "$SOURCE_DIR" -type f -name .htaccess -exec "$HTACCESS_CONVERT_UTIL" --quiet --test-only --invert-exit --input=\{\} \; -print 2>/dev/null > "$FILE_LIST"
    rc=$?
    if [ -r "$FILE_LIST" ]; then
      COUNT="$(wc -l "$FILE_LIST" | awk '{print $1;}')"
      if [ $? -eq 0 ]; then
        debug "found $COUNT .htaccess file(s)"
      fi
    fi
  fi
  if [ $rc -ne 0 ]; then
    echo "WARNING:  the find command exited with non-zero status: $rc"
  fi
  exit $rc
fi

#
# If no FILE_LIST path was provided, make a temp file:
#
if [ -z "$FILE_LIST" ]; then
  FILE_LIST="$(mktemp -t htaccess-convert-all.XXXXXX 2>/dev/null)"
  if [ $? -ne 0 ]; then
    echo "ERROR:  unable to create temporary file list"
    exit 1
  fi
  KEEP_FILE_LIST=0
  debug "temporary file list in '$FILE_LIST'"
fi

#
# Do the 'find' across the SOURCE_DIR directory tree, looking for .htaccess files
# that need to be updated:
#
debug "searching '$SOURCE_DIR' for .htaccess files needing updating"
(cd "$SOURCE_DIR"; find . -type f -name .htaccess -exec "$HTACCESS_CONVERT_UTIL" --quiet --test-only --invert-exit --input=\{\} \; -print 2>/dev/null > "$FILE_LIST")
rc=$?
if [ $rc -ne 0 ]; then
  echo "WARNING:  the find command exited with non-zero status: $rc"
fi

#
# Check if there's anything to convert:
#
COUNT="$(wc -l "$FILE_LIST" | awk '{print $1;}')"
if [ $? -eq 0 -a $COUNT -gt 0 ]; then
  debug "commence converting $COUNT .htaccess file(s)"
  debug_inc_level
  while IFS= read -rs HTACCESS_PATH; do
    if [[ $HTACCESS_PATH =~ ^\./(.*)$ ]]; then
      HTACCESS_PATH="${BASH_REMATCH[1]}"
      HTACCESS_DIR="$(dirname "$HTACCESS_PATH")"

      debug "$HTACCESS_PATH"
      debug_inc_level
      if [ ! -e "${DEST_DIR}/${HTACCESS_DIR}" ]; then
        if [ $MAKE_DIRS -ne 0 ]; then
          create_shadow_dir "$HTACCESS_DIR"
          if [ $? -ne 0 ]; then
            exit 1
          fi
        else
          echo "ERROR:  ${DEST_DIR}/${HTACCESS_DIR} does not exist"
          exit 1
        fi
      else
        if [ $NO_ACCESS_COPY -eq 0 -a "$EUID" -eq 0 ]; then
          debug "copying access settings '${SOURCE_DIR}/${HTACCESS_DIR}' => '${DEST_DIR}/${HTACCESS_DIR}'"
          copy_access_recursive "$HTACCESS_DIR"
          if [ $? -ne 0 ]; then
            exit 1
          fi
        fi
      fi

      # If necessary, archive-copy into the shadow tree to retain
      # file permissions, ownership, etc.
      if [ $NO_ACCESS_COPY -eq 0 -a "$EUID" -eq 0 ]; then
        debug "copying '${SOURCE_DIR}/${HTACCESS_PATH}' => '${DEST_DIR}/${HTACCESS_PATH}' to preserve mode/ownership"
        copy_htaccess "$HTACCESS_PATH"
        if [ $? -ne 0 ]; then
          echo "ERROR:  failed to copy source .htaccess to destination"
          exit 1
        fi
      fi

      # Do the conversion!!
      debug "converting '${SOURCE_DIR}/${HTACCESS_PATH}' => '${DEST_DIR}/${HTACCESS_PATH}'"
      "$HTACCESS_CONVERT_UTIL" --quiet --input="${SOURCE_DIR}/${HTACCESS_PATH}" --output="${DEST_DIR}/${HTACCESS_PATH}"
      case "$?" in

        1)
          echo "WARNING:  minor issues with ${SOURCE_DIR}/${HTACCESS_PATH}"
          ;;

        2)
          echo "ERROR:  major issues with ${SOURCE_DIR}/${HTACCESS_PATH}"
          ;;

      esac
      debug_dec_level
    fi
  done < "$FILE_LIST"
  debug_dec_level
fi

#
# Drop the FILE_LIST if necessary:
#
if [ -f "$FILE_LIST" -a $KEEP_FILE_LIST -eq 0 ]; then
  debug "removing file list '$FILE_LIST'"
  rm -f "$FILE_LIST"
fi
