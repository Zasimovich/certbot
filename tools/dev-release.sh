#!/bin/sh -xe
# Release dev packages to PyPI

Usage() {
    echo Usage:
    echo "$0 [ --production ]"
    exit 1
}

if [ "`dirname $0`" != "tools" ] ; then
    echo Please run this script from the repo root
    exit 1
fi

version=`grep "__version__" letsencrypt/__init__.py | cut -d\' -f2`
if [ "$1" = "--production" ] ; then
    echo Releasing production version "$version"...
    if ! echo "$version" | grep -q -e '[0-9]\+.[0-9]\+.[0-9]\+' ; then
        echo "Version doesn't look like 1.2.3"
    fi
    RELEASE_BRANCH="master"
else
    version="$version.dev$(date +%Y%m%d)1"
    RELEASE_BRANCH="dev-release"
    echo Releasing developer version "$version"...
fi

RELEASE_GPG_KEY=A2CFB51FA275A7286234E7B24D17C995CD9775F2
# Needed to fix problems with git signatures and pinentry
export GPG_TTY=$(tty)

# port for a local Python Package Index (used in testing)
PORT=${PORT:-1234}

# subpackages to be released
SUBPKGS=${SUBPKGS:-"acme letsencrypt-apache letsencrypt-nginx letshelp-letsencrypt"}
subpkgs_modules="$(echo $SUBPKGS | sed s/-/_/g)"
# letsencrypt_compatibility_test is not packaged because:
# - it is not meant to be used by anyone else than Let's Encrypt devs
# - it causes problems when running nosetests - the latter tries to
#   run everything that matches test*, while there are no unittests
#   there

tag="v$version"
mv "dist.$version" "dist.$version.$(date +%s).bak" || true
git tag --delete "$tag" || true

tmpvenv=$(mktemp -d)
virtualenv --no-site-packages -p python2 $tmpvenv
. $tmpvenv/bin/activate
# update setuptools/pip just like in other places in the repo
pip install -U setuptools
pip install -U pip  # latest pip => no --pre for dev releases
pip install -U wheel  # setup.py bdist_wheel

# newer versions of virtualenv inherit setuptools/pip/wheel versions
# from current env when creating a child env
pip install -U virtualenv

root="$(mktemp -d -t le.$version.XXX)"
echo "Cloning into fresh copy at $root"  # clean repo = no artificats
git clone . $root
git rev-parse HEAD
cd $root
git branch -f "$RELEASE_BRANCH"
git checkout "$RELEASE_BRANCH"

for pkg_dir in $SUBPKGS
do
  sed -i $x "s/^version.*/version = '$version'/" $pkg_dir/setup.py
done
sed -i "s/^__version.*/__version__ = '$version'/" letsencrypt/__init__.py

git add -p  # interactive user input
git commit --gpg-sign="$RELEASE_GPG_KEY" -m "Release $version"
git tag --local-user "$RELEASE_GPG_KEY" \
    --sign --message "Release $version" "$tag"

echo "Preparing sdists and wheels"
for pkg_dir in . $SUBPKGS
do
  cd $pkg_dir

  python setup.py clean
  rm -rf build dist
  python setup.py sdist
  python setup.py bdist_wheel

  echo "Signing ($pkg_dir)"
  for x in dist/*.tar.gz dist/*.whl
  do
      gpg2 --detach-sign --armor --sign $x
  done

  cd -
done

mkdir "dist.$version"
mv dist "dist.$version/letsencrypt"
for pkg_dir in $SUBPKGS
do
  mv $pkg_dir/dist "dist.$version/$pkg_dir/"
done

echo "Testing packages"
cd "dist.$version"
# start local PyPI
python -m SimpleHTTPServer $PORT &
# cd .. is NOT done on purpose: we make sure that all subpackages are
# installed from local PyPI rather than current directory (repo root)
virtualenv --no-site-packages ../venv
. ../venv/bin/activate
pip install -U setuptools
pip install -U pip
# Now, use our local PyPI
pip install \
  --extra-index-url http://localhost:$PORT \
  letsencrypt $SUBPKGS
# stop local PyPI
kill $!

# freeze before installing anything else, so that we know end-user KGS
# make sure "twine upload" doesn't catch "kgs"
mkdir ../kgs
kgs="../kgs/$version"
pip freeze | tee $kgs
pip install nose
nosetests letsencrypt $subpkgs_modules

echo "New root: $root"
echo "KGS is at $root/kgs"
echo "In order to upload packages run the following command:"
echo twine upload "$root/dist.$version/*/*"

echo "Edit and commit letsencrypt/__init__.py to contain the next anticipated"
echo "release version"
