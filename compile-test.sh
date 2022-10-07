#!/bin/bash -x

set -e            # fail fast
set -o pipefail   # don't ignore exit codes when piping output
# set -x          # enable debugging

# Enable extended globbing
shopt -s extglob

# Configure directories
cache_dir=$2
env_dir=$3
bp_dir=/build_files

# Option [nocl] to disable cleanup for testing
cleanup=$4

# Load some convenience functions like status(), echo(), and indent()
source $bp_dir/bin/common.sh

# Load user config
if [ -e $1/.client ]; then
  status "Load config from .client"
  source $1/.client
fi

# Client build directory
build_dir=$1/${CLIENT_DIR:-"client"}

# Grunt / Gulp task name
dist_dir=${DIST_DIR:-dist}

status "Client dir: ${CLIENT_DIR:-client}"
status "Dist dir: $dist_dir"

# Fix leak
status "Resetting git environment"
unset GIT_DIR

# Ignore NODE_ENV
unset NODE_ENV

# Output npm debug info on error
trap cat_npm_debug_log ERR

# Create default package.json
if [ ! -e $build_dir/package.json ]; then
	status "No package.json found; Adding gulp to new package.json"
	cat <<- EOF > $build_dir/package.json
	{
	  "name": "client",
	  "version": "0.0.1",
	  "description": "web client",
	  "private": true,
	  "devDependencies": {
		"gulp": "^3.9.0"
	  },
	  "engines": {
	    "node": "~0.10.37"
	  }
	}
	EOF
fi

# Look in package.json's engines.node field for a semver range
semver_range=$(cat $build_dir/package.json | $bp_dir/vendor/jq -r .engines.node)

# Resolve node version using semver.io
node_version=$semver_range

# Recommend using semver ranges in a safe manner
if [ "$semver_range" == "null" ]; then
  protip "Specify a node version in package.json"
  semver_range=""
elif [ "$semver_range" == "*" ]; then
  protip "Avoid using semver ranges like '*' in engines.node"
elif [ ${semver_range:0:1} == ">" ]; then
  protip "Avoid using semver ranges starting with '>' in engines.node"
fi

# Output info about requested range and resolved node version
if [ "$semver_range" == "" ]; then
  status "Defaulting to latest stable node: $node_version"
else
  status "Requested node range:  $semver_range"
  status "Resolved node version: $node_version"
fi

# Download node from Heroku's S3 mirror of nodejs.org/dist
status "Downloading and installing node"
node_url="https://nodejs.org/dist/v$node_version/node-v$node_version-linux-x64.tar.gz"
curl $node_url -s -o - | tar xzf - -C $build_dir

# Move node (and npm) into ./vendor and make them executable
mkdir -p $build_dir/vendor
mv $build_dir/node-v$node_version-linux-x64 $build_dir/vendor/node
chmod +x $build_dir/vendor/node/bin/*
PATH=$build_dir/vendor/node/bin:$PATH

# Run subsequent node/npm commands from the build path
cd $build_dir

npm_version=$(npm -v)
status "Using npm version: $npm_version"

# If node_modules directory is checked into source control then
# rebuild any native deps. Otherwise, restore from the build cache.
if test -d $build_dir/node_modules; then
  status "Found existing node_modules directory; skipping cache"
  status "Rebuilding any native dependencies"
  npm rebuild 2>&1 | indent
elif test -d $cache_dir/node/node_modules; then
  status "Restoring node_modules directory from cache"
  cp -r $cache_dir/node/node_modules $build_dir/

  status "Pruning cached dependencies not specified in package.json"
  npm prune 2>&1 | indent

  if test -f $cache_dir/node/.heroku/node-version && [ $(cat $cache_dir/node/.heroku/node-version) != "$node_version" ]; then
    status "Node version changed since last build; rebuilding dependencies"
    npm rebuild 2>&1 | indent
  fi

fi

# Scope config var availability only to `npm install`
(
  if [ -d "$env_dir" ]; then
    status "Exporting config vars to environment"
    export_env_dir $env_dir
  fi

  status "Installing dependencies"
  npm link --local
  # Make npm output to STDOUT instead of its default STDERR
  npm install --userconfig $build_dir/.npmrc 2>&1 | indent
)

# Persist goodies like node-version in the slug
mkdir -p $build_dir/.heroku

# Save resolved node version in the slug for later reference
echo $node_version > $build_dir/.heroku/node-version

# Purge node-related cached content, being careful not to purge the top-level
# cache, for the sake of heroku-buildpack-multi apps.
rm -rf $cache_dir/node_modules # (for apps still on the older caching strategy)
rm -rf $cache_dir/node
mkdir -p $cache_dir/node

# If app has a node_modules directory, cache it.
if test -d $build_dir/node_modules; then
  status "Caching node_modules directory for future builds"
  cp -r $build_dir/node_modules $cache_dir/node
fi

# Copy goodies to the cache
cp -r $build_dir/.heroku $cache_dir/node

status "Cleaning up node-gyp and npm artifacts"
rm -rf "$build_dir/.node-gyp"
rm -rf "$build_dir/.npm"


# Install bower dependencies
if [ -e $build_dir/bower.json ]; then
  status "Install bower dependencies"
  if test -d $cache_dir/.bowercache; then
    status "Restoring bower components from cache"
    cp -r $cache_dir/.bowercache $build_dir
    HOME=$build_dir $build_dir/node_modules/.bin/bower install --config.storage.packages=$build_dir/.bowercache 2>&1 | indent
  else
    HOME=$build_dir $build_dir/node_modules/.bin/bower install --config.storage.packages=$build_dir/.bowercache 2>&1 | indent
  fi

  # Cache bower
  rm -rf $cache_dir/.bowercache
  mkdir -p $cache_dir/.bowercache

  # If app has a bower directory, cache it.
  if test -d $build_dir/.bowercache; then
    status "Caching bower cache directory for future builds"
    cp -r $build_dir/.bowercache $cache_dir
  fi
fi

# Run gulp
status "Running gulp compile task"
$build_dir/node_modules/.bin/gulp compile 2>&1 | indent

# Update the PATH
status "Building runtime environment"
mkdir -p $build_dir/.profile.d
echo "export PATH=\"\$HOME/vendor/node/bin:\$HOME/bin:\$HOME/node_modules/.bin:\$PATH\";" > $build_dir/.profile.d/nodejs.sh
echo "export PATH=\"\$HOME/.gem/$RUBY_VERSION/bin:\$PATH\"" > $build_dir/.profile.d/ruby.sh

# Cleanup
if [ "$cleanup" != "nocl" ]; then
  status "Cleanup"
  rm -rf !(${dist_dir})
fi
