#!/usr/bin/env bash

source ${APP_DIR}/ci_cd/concourse/bin/init.sh

set -e -x

./bin/validate.sh
