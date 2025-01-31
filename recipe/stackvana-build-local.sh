#!/bin/bash

echo "=========================================================================="
echo "environment"
echo "=========================================================================="
env | sort
echo "=========================================================================="
echo "=========================================================================="
echo " "

if [[ ! ${STACKVANA_ACTIVATED} ]]; then
    echo "the stackvana-core package must be activated in order to build the stack!"
    exit 1
fi

if [[ "${PREFIX}" != "${CONDA_PREFIX}" ]]; then
    echo "you need to set build/merge_build_host to True in order to build with stackvana!"
    exit 1
fi

# conda env includes are searched after the command line -I paths
export CPATH="${CONDA_PREFIX}/include"

# add conda env libraries for linking
export LIBRARY_PATH="${CONDA_PREFIX}/lib"

# set rpaths to resolve links properly at run time and remove a problematic flag for osx
if [[ `uname -s` == "Darwin" ]]; then
    export LDFLAGS="${LDFLAGS//-Wl,-dead_strip_dylibs} -Wl,-rpath,${CONDA_PREFIX}/lib -L${CONDA_PREFIX}/lib"
    export LDFLAGS_LD="${LDFLAGS_LD//-dead_strip_dylibs} -rpath ${CONDA_PREFIX}/lib -L${CONDA_PREFIX}/lib"
else
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,${CONDA_PREFIX}/lib -Wl,-rpath-link,${CONDA_PREFIX}/lib -L${CONDA_PREFIX}/lib"
fi

function _report_errors {
    which butler
    cat `which butler` || echo "no butler to cat!"

    for pth in "${EUPS_PATH}/EupsBuildDir/*/*/build.log" \
        "${EUPS_PATH}/EupsBuildDir/*/*/*/config.log" \
        "${EUPS_PATH}/EupsBuildDir/*/*/*/CMakeFiles/*.log" \
        "${EUPS_PATH}/EupsBuildDir/*/*/*/tests/.tests/*"; do

        for fname in `compgen -G $pth`; do
            echo "================================================================="
            echo "================================================================="
            echo "================================================================="
            echo "================================================================="
            echo "${fname}:"
            echo "================================================================="
            echo "================================================================="
            echo " "
            cat ${fname}
            echo " "
            echo " "
        done
    done

    # undo the shim
    if [[ `uname -s` == "Darwin" ]]; then
        echo "Undoing the OSX python shim..."
        mv ${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak ${CONDA_PREFIX}/bin/python${LSST_PYVER}
        # leave behind a symlink just in case this path propagates?
        # ln -s ${CONDA_PREFIX}/bin/python${LSST_PYVER} ${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak
        echo " "
    fi

    exit 1
}

# this shim is here to bypass SIP for running the OSX tests.
# the conda-build prefixes are very long and so the pytest
# command line tool gets /usr/bin/env put in for the prefix.
# invoking env causes SIP to be invoked and all of the DYLD_LIBRARY_PATHs
# get swallowed. Here we reinsert them right before the python executable.
if [[ `uname -s` == "Darwin" ]]; then
    echo "Making the python shim for OSX..."
    mv ${CONDA_PREFIX}/bin/python${LSST_PYVER} ${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak
    echo "\
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int prepend_env(char *envname, char *envval) {
  char *curr_val = getenv(envname);
  int rval;
  char *new_val = NULL;
  int new_len;

  if (curr_val != NULL) {
      new_len = strlen(curr_val) + strlen(envval) + 1 + 1;
      new_val = (char*)malloc(sizeof(char) * new_len);
      sprintf(new_val, \"%s:%s\", envval, curr_val);
      rval = setenv(envname, new_val, 1);
      free(new_val);
  } else {
    rval = setenv(envname, envval, 1);
  }

  return rval;
}

int main(int argc, char **argv) {
  const char *orig_py = \"${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak\";
  char *lsst_lib_path = getenv(\"LSST_LIBRARY_PATH\");
  if (lsst_lib_path != NULL) {
    prepend_env(\"DYLD_LIBRARY_PATH\", lsst_lib_path);
    prepend_env(\"DYLD_FALLBACK_LIBRARY_PATH\", lsst_lib_path);
  }
  argv[0] = orig_py;
  execv(orig_py, argv);
}
" > main.c
    ${CC} ${CFLAGS} ${LDFLAGS} main.c -o ${CONDA_PREFIX}/bin/python${LSST_PYVER}
    chmod u+x ${CONDA_PREFIX}/bin/python${LSST_PYVER}
    echo " "
fi

echo "Running eups install..."
{
    eups distrib install -v -t ${LSST_DM_TAG} $@
} || {
    _report_errors
}
echo " "

# undo the shim
if [[ `uname -s` == "Darwin" ]]; then
    echo "Undoing the OSX python shim..."
    mv ${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak ${CONDA_PREFIX}/bin/python${LSST_PYVER}
    # leave behind a symlink just in case this path propagates?
    # ln -s ${CONDA_PREFIX}/bin/python${LSST_PYVER} ${CONDA_PREFIX}/bin/python${LSST_PYVER}.bak
    echo " "
fi

# fix up the python paths
# we set the python #! line by hand so that we get the right thing coming out
# in conda build for large prefixes this always has /usr/bin/env python
echo "Fixing the python scripts with shebangtron..."
export SHTRON_PYTHON=${CONDA_PREFIX}/bin/python
curl -sSL https://raw.githubusercontent.com/lsst/shebangtron/master/shebangtron | ${PYTHON}
echo " "

echo "Cleaning up extra data..."
# clean out .pyc files made by eups installs
# these cause problems later for a reason I don't understand
# conda remakes them IIUIC
for dr in ${LSST_HOME} ${CONDA_PREFIX}/lib/python${LSST_PYVER}/site-packages; do
    pushd $dr
    if [[ `uname -s` == "Darwin" ]]; then
        find . -type f -name '*.py[co]' -delete -o -type d -name __pycache__ -delete
    else
        find . -regex '^.*\(__pycache__\|\.py[co]\)$' -delete
    fi
    popd
done

# clean out any documentation
# this bloats the packages, is usually a ton of files, and is not needed
compgen -G "${EUPS_PATH}/*/*/*/tests/.tests/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/tests/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/bin.src/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/doc/html/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/doc/xml/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/share/doc/*" | xargs rm -rf
compgen -G "${EUPS_PATH}/*/*/*/share/man/*" | xargs rm -rf

# remove the global tags file since it tends to leak across envs
rm -f ${EUPS_PATH}/ups_db/global.tags
