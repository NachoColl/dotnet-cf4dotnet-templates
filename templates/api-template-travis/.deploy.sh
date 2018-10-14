#!/bin/bash

#############################################################################
# The ENVIRONMENT VARIABLES you must set on TRAVIS:                         #    
#   AWS_ACCOUNT_test                                                        #
#   AWS_ACCOUNT_staging                                                     #
#   AWS_ACCOUNT_prod                                                        #
#   AWS_ACCESS_KEY_ID                                                       #
#   AWS_SECRET_ACCESS_KEY                                                   #
#   AWS_DEPLOY_ROLE (use the same name for all the accounts)                #
#   AWS_DEFAULT_REGION                                                      #
#############################################################################

set -e

#################
# ARGUMENTS     #
#################

# test, staging or prod
ENVIRONMENT=$1
# the csproj file name
CSPROJ_FILENAME=$2
# assembly filename as mentioned at the .csproj
ASSEMBLY_FILENAME=$3
# a tag used to identify resources on AWS
TAG_CODE=$4


# STEP 1
###################################################
# SET AWS Credentials        

AWS_ACCOUNT=$(case $ENVIRONMENT in test) echo $AWS_ACCOUNT_test ;; staging) echo $AWS_ACCOUNT_staging ;; prod) echo $AWS_ACCOUNT_prod ;; esac)
AWS_ROLE=$(echo arn:aws:iam::$AWS_ACCOUNT:role/$AWS_DEPLOY_ROLE)

echo "deploying to $AWS_ACCOUNT account using $AWS_ROLE role"
# create AWS .config credentials file 
echo "setting credentials"
aws configure set default.aws_access_key_id $AWS_ACCESS_KEY_ID
aws configure set default.aws_secret_access_key $AWS_SECRET_ACCESS_KEY
aws configure set default.region $AWS_DEFAULT_REGION
aws configure set profile.deploy.role_arn $AWS_ROLE
aws configure set profile.deploy.source_profile default

# STEP 2
###################################################
# BUILD ARTIFACTS            

# csproj files
CSPROJ_FULLPATH=$(echo $TRAVIS_BUILD_DIR/src/$CSPROJ_FILENAME.csproj)

# artifacts local output location
ARTIFACT_PATH=$(echo $TRAVIS_BUILD_DIR/artifacts/)
ARTIFACT_FILENAME=$(echo $ENVIRONMENT-$TRAVIS_BUILD_NUMBER.zip)
ARTIFACT_FULLPATH=$(echo $ARTIFACT_PATH/$ARTIFACT_FILENAME)

echo "creating artifact"
# define code constants
sed -i -e "s/RELEASE/${ENVIRONMENT^^}/g" $CSPROJ_FULLPATH
# publish dotnet code
dotnet publish $TRAVIS_BUILD_DIR/src -o $ARTIFACT_PATH --framework netcoreapp2.1 --runtime linux-x64 -c Release
# package code
echo "packaging artifact"
zip -j $ARTIFACT_FULLPATH $ARTIFACT_PATH/* 

# results example: ./artifacts/prod-34.zip
###################################################

# STEP 3
###################################################
# SEND ARTIFACTS TO S3       


# artifact location on AWS S3
S3_BUCKET=$(echo cf4dotnet-$AWS_ACCOUNT)
S3_ARTIFACT_BUCKET=$(echo s3://$S3_BUCKET/api)
S3_ARTIFACT_URI=$(echo $S3_ARTIFACT_BUCKET/$ARTIFACT_FILENAME)

# upload code to S3 deployment bucket
echo "copying artifact to s3"
aws s3 --profile deploy cp $ARTIFACT_FULLPATH $S3_ARTIFACT_URI

# results example: s3://cf4dotnet-36634273/api/prod-34.zip
############################################################################

# STEP 4
############################################################################
# BUILD cloudformation templates    

# cloudformation injection project
CF4DOTNET_SOURCE_DLL=$(echo $ARTIFACT_PATH/$ASSEMBLY_FILENAME.dll)

echo "building injected template"
dotnet cf4dotnet api $CF4DOTNET_SOURCE_DLL -b $TRAVIS_BUILD_NUMBER -e $ENVIRONMENT

# results example: ./sam-base.yml and ./sam-prod.yml
############################################################################

# STEP 5
############################################################################
# deploy templates to AWS   


CF_BASE_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/sam-base.yml)
CF_ENVIRONMENT_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/sam-$ENVIRONMENT.yml)

CF_BASE_STACKNAME=$(echo $TAG_CODE-base)
CF_ENVIRONMENT_STACKNAME=$(echo $TAG_CODE-$ENVIRONMENT)

# deploy base template
echo "deploy CF base template"
aws cloudformation deploy --profile deploy --template-file $CF_BASE_TEMPLATE --stack-name $CF_BASE_STACKNAME --parameter-overrides PackageBaseFileName=$ENVIRONMENT PackageVersion=$TRAVIS_BUILD_NUMBER S3Bucket=$S3_BUCKET --tags appcode=$TAG_CODE --no-fail-on-empty-changeset 

# deploy environment template
echo "deploy CF environment template"
aws cloudformation deploy --profile deploy --template-file $CF_ENVIRONMENT_TEMPLATE --stack-name $CF_ENVIRONMENT_STACKNAME --tags appcode=$TAG_CODE --no-fail-on-empty-changeset 

# results: your code is on AWS!
############################################################################