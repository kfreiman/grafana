#!/usr/bin/env bash

PACKAGES=(ui toolkit data runtime e2e)

# shellcheck source=./scripts/helpers/exit-if-fail.sh
source "$(dirname "$0")/helpers/exit-if-fail.sh"

function parse_git_hash() {
  git rev-parse --short HEAD 2> /dev/null | sed "s/\(.*\)/\1/"
}

function prapare_version_commit () {
  echo $'\nCommiting version changes. This commit will not be checked-in!'
  git config --global user.email "circleci@grafana.com"
  git config --global user.name "CirceCI"
  git commit -am "Version commit"
}

function unpublish_previous_canary () {
  echo $'\nUnpublishing previous canary packages'
  for PACKAGE in "${PACKAGES[@]}"
  do
    # dist-tag next to be changed to canary when https://github.com/grafana/grafana/pull/18195 is merged
    CURRENT_CANARY=$(npm view @grafana/"${PACKAGE}" dist-tags.canary)
    if [ -z "${CURRENT_CANARY}" ]; then
        echo "@grafana/${PACKAGE} - Nothing to unpublish"
    else
      echo "Unpublish @grafana/${PACKAGE}@${CURRENT_CANARY}"
      npm unpublish "@grafana/${PACKAGE}@${CURRENT_CANARY}" || (
        # We want to deprecate here, rather than fail and return an non-0 exit code
        npm deprecate \
          "@grafana/${PACKAGE}@${CURRENT_CANARY}" \
          "Unpublish failed with [$?]. Deprecating \"@grafana/${PACKAGE}@${CURRENT_CANARY}\"" || (
            # Echoing a log message will ultimately change the error code, so save the error
            # code and return it after printing an error log.
            echo "Could not deprecate \"@grafana/${PACKAGE}@${CURRENT_CANARY}\". Received exit-code [$?]"
        )
      )
    fi
  done
}

# Get current version from lerna.json
PACKAGE_VERSION=$(grep '"version"' lerna.json | cut -d '"' -f 4)
# Get  current commit's short hash
GIT_SHA=$(parse_git_hash)

echo "Commit: ${GIT_SHA}"
echo "Current lerna.json version: ${PACKAGE_VERSION}"

# check if there were any changes to packages between current and previous commit
count=$(git diff HEAD~1..HEAD --name-only -- packages | awk '{c++} END {print c}')

if [ -z "$count" ]; then
  echo "No changes in packages, skipping packages publishing"
else
  echo "Changes detected in ${count} packages"
  echo "Releasing packages under ${PACKAGE_VERSION}-${GIT_SHA}"
  npx lerna version "${PACKAGE_VERSION}-${GIT_SHA}" --no-git-tag-version --no-push --force-publish -y
  echo $'\nGit status:'
  git status -s


  echo $'\nBuilding packages'

  for PACKAGE in "${PACKAGES[@]}"
  do
    start=$(date +%s%N)
    yarn workspace @grafana/"${PACKAGE}" run build
    runtime=$((($(date +%s%N) - start)/1000000))
    if [ "${CIRCLE_BRANCH}" == "master" ]; then
    exit_if_fail ./scripts/ci-metrics-publisher.sh "grafana.ci-buildtimes.$CIRCLE_JOB.$PACKAGE=$runtime"
    fi
  done

  exit_status=$?
  if [ $exit_status -eq 1 ]; then
    echo "Packages build failed, skipping canary release"
    # TODO: notify on slack/email?
    exit
  fi
  prapare_version_commit

  unpublish_previous_canary

  echo $'\nPublishing packages'
  yarn packages:publishCanary
fi

