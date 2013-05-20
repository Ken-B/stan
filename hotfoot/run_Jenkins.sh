#!/bin/bash

parse_output() {
case "$1" in
'test-unit')
SE = ${TUSE}
SO = ${TUSO}
;;
'test-models')
SE = ${TMSE}
SO = ${TMSO}
;;
'test-distributions')
SE = ${TDSE}
SO = ${TDSO}
;;
)
echo "Invalid input to parse_output()"
exit 1
;;
esac

ERRORS=`grep -l -F "error:" ${SE}/*`
if [ -z "$ERRORS" ]
then
  echo "${1} has build, link, etc. errors"
  echo ${ERRORS}
  exit 10
fi

FAILURES=`grep -l -F -i "fail" ${SO}/*
if [ -z "$FAILURES" ]
then
  echo "${1} has test failures at runtime"
  echo ${FAILURES}
  echo "Possible warnings associated with test failures"
  echo ${FAILURES//stdout/stderr}
  exit 20
fi

exit 0
}

# All of these environmental variables are exported when calling qsub
# These two are supposedly exported by Jenkins
#GIT_COMMIT=`git rev-parse HEAD`
#GIT_BRANCH=`git rev-parse --abbrev-ref HEAD`
CC=clang++ # TODO: ccache
STAN_HOME=/usr/stats/projects/stan

cd ${STAN_HOME}

# Tweak CFLAGS but revert on exit
if [[ ${GIT_BRANCH} != "master" && ${GIT_BRANCH} != hotfix* && ${GIT_BRANCH} != release* ]]
then
  sed -i 's@^CFLAGS =@CFLAGS = --std=c++11 -DGTEST_HAS_PTHREAD=0 -pedantic -Wextra @/' makefile
  sed -i '/-Wno/d' make/os_linux
  trap "git checkout ${GIT_COMMIT}" EXIT
fi

CODE=0
# Create dependencies of tests
((CODE++))
make clean-all &> /dev/null
if [ $? -ne 0 ]
then
  echo "make clean-all failed; aborting"
  exit ${CODE}
fi

((CODE++))
nice make CC=${CC} -j4 test/libgtest.a
if [ $? -ne 0 ]
then
  echo "make test/libgtest.a failed; aborting"
  exit ${CODE}
fi

((CODE++))
nice make CC=${CC} -j4 bin/libstan.a
if [ $? -ne 0 ]
then
  echo "make bin/libstan.a failed; aborting"
  exit ${CODE}
fi

((CODE++))
nice make CC=${CC} -j4 bin/stanc
if [ $? -ne 0 ]
then
  echo "make bin/stanc failed; aborting"
  exit ${CODE}
fi

OUTPUT=${STAN_HOME}/hotfoot/${GIT_BRANCH}/${GIT_COMMIT}
trap "rm -rf hotfoot/$GIT_BRANCH}" EXIT

# Gather *_test.cpp files under src/test/, excluding src/test/models/
unset TEST_UNIT_ARRAY
unset i
while IFS= read -r -d $'\0' file; do
  if [[ "$file" != *src/test/models/* ]]
  then
    TEST=${file#"src/"}
    TEST_UNIT_ARRAY[i++]=${TEST%"_test.cpp"}
  fi
done < <(find src/test/ -type f -name "*_test.cpp" -print0)

# Execute these tests individually but in parallel using a job array
TUSO=${OUTPUT}/test-unit/stdout
TUSE=${OUTPUT}/test-unit/stderr
mkdir -p ${TUSO}
mkdir -p ${TUSE}

TEST_UNIT_ARRAY_MAX=`expr ${#TEST_UNIT_ARRAY[@]} - 1`
qsub -t 0-${TEST_UNIT_ARRAY_MAX} -o localhost:${TUSO} -e localhost:${TUSE} -I \
-x hotfoot/test-unit.sh
CODE = parse_output()
[ ${CODE} -ne 0 ] && exit ${CODE}

# Gather model tests
unset TEST_MODELS_ARRAY
unset i
while IFS= read -r -d $'\0' file; do
  TEST=${file#"src/"}
  TEST_MODELS_ARRAY[i++]=${TEST%"_test.cpp"}
done < <(find src/test/models -type f -name "*_test.cpp" -print0)

# Execute these tests individually but in parallel using a job array
TMSO=${OUTPUT}/test-models/stdout
TMSE=${OUTPUT}/test-models/stderr
mkdir -p ${TDSO}
mkdir -p ${TDSE}

TEST_MODELS_ARRAY_MAX=`expr ${#TEST_MODELS_ARRAY[@]} - 1`
qsub -t 0-${TEST_MODELS_ARRAY_MAX} -o localhost:${TMSO} -e localhost:${TMSE} -I \
-x hotfoot/test-models.sh
CODE = parse_output()
[ ${CODE} -ne 0 ] && exit ${CODE}

exit 0 # FIXME: Gather distribution tests
unset TEST_DISTRIBUTIONS_ARRAY
unset i
while IFS= read -r -d $'\0' file; do
    TEST=${file#"src/"}
    TEST_UNIT_ARRAY[i++]=${TEST%"_test.cpp"}
  fi
done < <(find src/test/agrad/distributions -type f -name "*_test.hpp" -print0)

# Execute these tests individually but in parallel using a job array
TDSO=${OUTPUT}/test-distributions/stdout
TDSE=${OUTPUT}/test-distributions/stderr
mkdir -p ${TDSO}
mkdir -p ${TDSE}

TEST_DISTRIBUTIONS_ARRAY_MAX=`expr ${#TEST_DISTRIBUTIONS_ARRAY[@]} - 1`
qsub -t 0-${TEST_DISTRIBUTIONS_ARRAY_MAX} -o localhost:${TDSO} -e localhost${TDSE} -I \
-x hotfoot/test-distributions.sh
CODE = parse_output()
[ ${CODE} -ne 0 ] && exit ${CODE}

echo "All tests passed on Hotfoot for branch ${GIT_BRANCH} and commit ${GIT_COMMIT}"
echo "But the following are all the unique lines with warnings:"
grep -r -h -F "warning:" hotfoot/${GIT_BRANCH}/${GIT_COMMIT}/ \
--exclude-dir=${TUSO} --exclude-dir=${TMSO} --exclude-dir=${TDSO}  | grep ^src | sort | uniq

exit 0
