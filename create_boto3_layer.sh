#!/bin/sh

# Copyright 2019 Jerome Van Der Linden
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#    http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

boto3version=""
region=""
pythonversion=""

for i in "$@"
do 
  case "$i" in
    -r=*|--region=*)
       region="${i#*=}"
       ;;
    -b=*|--boto3=*)
       boto3version="${i#*=}"
       ;;
    -p=*|--python=*)
       pythonversion="${i#*=}"
       if [ $pythonversion != '3.10' ] && [ $pythonversion != '3.11' ] && [ $pythonversion != '3.12' ] 
       then
         echo "Possible values for python version: 3.10 | 3.11 | 3.12"
         exit 1
       fi
       ;;
    -h|--help)
       helpmessage="
\n
NAME \n
\t create_boto3_layer\n
\n
DESCRIPTION\n
\t Create an AWS Lambda Layer for boto3, to be included in a Lambda function after.\n
\t See https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html\n
\t Needs AWS CLI to be configured and Docker\n
\n
OPTIONS\n
\t -h | --help : Display this help\n
\n
\t  -b | --boto3 : (Optional) Specify the version of boto3.\n
\t\t\t If not specified, will retrieve the latest version.\n
\n
\t -p | --python : (Optional) Specify the version of python for which you want to create the layer.\n
\t\t\t If not specified, will create for all versions of python.\n
\t\t\t Possible values: 3.10 | 3.11 | 3.12\n
\n
\t  -r | --region : (Optional) Specify the region in which you want to create the layer.\n
\t\t\t If not specified, use the region configured with AWS cli.\n
       "
       echo ${helpmessage}
       exit 0
       ;;
    *)
       echo "Unknown parameter $i, use -h or --help to get available options"
       exit 3
       ;;
  esac
done

if [ -z "${boto3version}" ]; then
  echo "No version provided, looking up for latest version of boto3..."
  boto3version=`curl -s https://pypi.org/pypi/boto3/json | jq -r .info.version`
fi

if [ -z "${region}" ]; then
  echo "No region provided, using aws cli configuration..."
  region=`aws configure get region`
fi

read -n 1 -p "Do you want to create a layer for boto 3 version ${boto3version} in ${region}? (y|n) " install
if [ $install != 'y' ] && [ $install != 'Y' ] 
then
  echo ""
  echo "Bye bye"
  exit 0
fi

echo ""
echo "#################################################"
echo "Building package for boto 3 version $boto3version"
echo "#################################################"

buildpython() 
{
  pyversion=$1
  echo "### Building boto 3 package for python ${pyversion}"
  mkdir -p "/tmp/python/lib/python${pyversion}/site-packages"
  cd "/tmp/python/lib/python${pyversion}/site-packages"
  docker run -v "$PWD":/var/task "amazonlinux:latest" /bin/sh -c "cd /var/task; yum update; yum install python3-pip -y; pip install boto3==$boto3version -t .; exit"
}

rm -rf /tmp/python
rm -rf /tmp/boto3_v*.zip

if [ -z "${pythonversion}" ]; then
  # Python 3.10
  buildpython "3.10"

  # Python 3.11
  buildpython "3.11"

  # Python 3.12
  buildpython "3.12"
  
  cd /tmp
  zip -r boto3-$boto3version.zip python > /dev/null
else 
  buildpython "${pythonversion}"
  cd /tmp
  zip -r boto3-$boto3version-python$pythonversion.zip python/lib/python$pythonversion/site-packages > /dev/null
fi

echo ""
echo "#####################################################"
echo "Deploy boto 3 version $boto3version as a Lambda layer"
echo "#####################################################"
echo "Please wait..."

boto3layerversion=`echo "${boto3version}" | sed s/"\."/"-"/g`

if [ -z "${pythonversion}" ]; then
  result=`aws lambda publish-layer-version --layer-name boto3_v${boto3layerversion} --description "Boto 3 version ${boto3version}" --zip-file fileb://boto3-$boto3version.zip --compatible-runtimes "python3.10" "python3.11" "python3.12" --region ${region}`
else
  pyversion=`echo "${pythonversion}" | sed s/"\."/""/g`
  result=`aws lambda publish-layer-version --layer-name boto3_v${boto3layerversion}_py${pyversion} --description "Boto 3 version ${boto3version} for python ${pythonversion}" --zip-file fileb://boto3-$boto3version-python$pythonversion.zip --compatible-runtimes "python${pythonversion}" --region ${region}`
fi

arn=`echo ${result} | jq -r .LayerVersionArn`
echo ""
echo "Successfully deployed"
echo ""
echo "If you want to apply the layer to a lambda function, you can just type:"
echo "aws lambda update-function-configuration --layers $arn --region $region --function-name my-function"
echo ""
