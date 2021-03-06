#!/bin/sh
set -e
#
# This script is meant for quick & easy install via:
#   curl -sSL https://healthcatalyst.github.io/InstallScripts/installmachinelearningunitypoint.txt | sh -s <username> <domain> <password>

u="$(whoami)"
echo "Running version 1.09 as: $u"

username="$1"
domain="$2"
password="$3"

echo "User name: $username"

if [ ! -z "$username" ]; then
    if [ -z "$password" ]; then
        echo "Please enter password for $username@$domain:"
        read -e password < /dev/tty     
    fi
fi

echo "stopping existing docker container"
docker stop fabric.machinelearning.unitypoint || echo 'no container to stop'
echo "removing docker container"
docker rm fabric.machinelearning.unitypoint || echo 'no container to remove'
echo "removing docker image"
docker rmi healthcatalyst/fabric.machinelearning.unitypoint || echo 'no image to remove'
echo "pulling latest docker image from repo"
docker pull healthcatalyst/fabric.machinelearning.unitypoint

echo "starting docker container with new image."

docker run -d --privileged=true --restart=unless-stopped -p 8080:8080 --name fabric.machinelearning.unitypoint healthcatalyst/fabric.machinelearning.unitypoint

echo "sleeping until docker container is up"
#until [ "`/usr/bin/docker inspect -f {{.State.Running}} fabric.machinelearning.unitypoint`"=="true" ]; do
#    sleep 1s;
#done;

sleep 5s;

# if username was passed then create a keytab file in docker container

if [ ! -z "$username" ]; then
    echo "creating keytab file for username & password"
    docker exec fabric.machinelearning.unitypoint opt/install/setupkeytab.sh $username $domain $password
fi
