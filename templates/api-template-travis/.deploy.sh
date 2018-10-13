#!/bin/bash

#############################################################################
# Expected ENVIRONMENT VARIABLES on TRAVIS:                                 #    
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
# project file name (e.g. MyProject)
CSPROJ_FILENAME=$2
# test project file name (e.g. MyTests)
CSPROJ_TEST_FILENAME=$3

######################################
# STEP 1: SET AWS Credentials        #
######################################

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

######################################
# STEP 2: BUILD ARTIFACTS           #
######################################

# csproj files
PROJECT_FILE=$(echo $TRAVIS_BUILD_DIR/src/$CSPROJ_FILENAME.csproj)
PROJECT_FILE_TEST=$(echo $TRAVIS_BUILD_DIR/test/$CSPROJ_TEST_FILENAME.csproj)

# artifacts local output location
ARTIFACT_PATH=$(echo $TRAVIS_BUILD_DIR/artifacts/)
ARTIFACT_FILENAME=$(echo $ENVIRONMENT-$TRAVIS_BUILD_NUMBER.zip)
ARTIFACT_FULLPATH=$(echo $TRAVIS_BUILD_DIR/artifacts/$ARTIFACT_FILENAME)

echo "creating artifact"
# define code constants
sed -i -e "s/RELEASE/${ENVIRONMENT^^}/g" $PROJECT_FILE
# publish dotnet code
dotnet publish $PROJECT_FILE -o $ARTIFACT_PATH --framework netcoreapp2.1 --runtime linux-x64 -c Release
# package code
echo "packaging artifact"
zip -j $ARTIFACT_FULLPATH $ARTIFACT_PATH/* 

######################################
# STEP 2: SEND ARTIFACTS TO S3       #
######################################

# artifact location on AWS S3
S3_BUCKET=$(echo deployments-$AWS_ACCOUNT)
S3_ARTIFACT_BUCKET=$(echo s3://$S3_BUCKET/api)
S3_ARTIFACT_URI=$(echo $S3_ARTIFACT_BUCKET/$ARTIFACT_FILENAME)

# upload code to S3 deployment bucket
echo "copying artifact to s3"
aws s3 --profile deploy cp $ARTIFACT_FULLPATH $S3_ARTIFACT_URI

#############################################
# STEP 3: BUILD cloudformation templates    #
#############################################


# cloudformation injection project
INJECTION_DLL_FILE=$(echo $ARTIFACT_PATH/nwayapi.dll)
INJECTION_FILESPATH=$(echo $TRAVIS_BUILD_DIR/deploy)
INJECTION_PROJECT_FILE=$(echo $TRAVIS_BUILD_DIR/deploy/injection.csproj)

# local cloudformation templates
CF_DATABASE_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/deploy/dynamodb.yml)
CF_BASE_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/sam-base.yml)
CF_INJECTED_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/deploy/sam-$ENVIRONMENT.yml)

# SNS
SNS_RESULTS_TOPIC=$(echo arn:aws:sns:us-east-1:$AWS_ACCOUNT:nway-deployments)
# AWS cloudformation STACKS
CF_DATABASE_STACKNAME=$(echo nway-api-dynamodb)
CF_BASE_STACKNAME=$(echo nway-api)
CF_INJECTED_STACKNAME=$(echo nway-api-$ENVIRONMENT)


##############################################
# dynamically create CF API templates
##############################################

# get the last deployed artifact for this deployment (lambda N-1 must reference previous code version!)
# echo $S3_ARTIFACT_BUCKET
#PREVIOUS_RELEASE_NUMBER=$(echo aws s3 --profile deploy ls $S3_ARTIFACT_BUCKET/$ARTIFACT_BASEFILENAME | awk '{print $4}' | sed 's/[^0-9]*//g' | sort -n | tail -1)
# echo $PREVIOUS_RELEASE_NUMBER

echo "building injected template"
dotnet run --project $INJECTION_PROJECT_FILE -- $INJECTION_DLL_FILE $INJECTION_FILESPATH $ENVIRONMENT $TRAVIS_BUILD_NUMBER


##############################################
# execute CF API templates
##############################################

# deploy base template
echo "deploy CF base template"
cat $CF_BASE_TEMPLATE
aws cloudformation deploy --profile deploy --template-file $CF_BASE_TEMPLATE --stack-name $CF_BASE_STACKNAME --parameter-overrides PackageBaseFileName=$ARTIFACT_BASEFILENAME PackageVersion=$TRAVIS_BUILD_NUMBER S3Bucket=$S3_BUCKET --tags appcode=nway --no-fail-on-empty-changeset 

# deploy environment template
echo "deploy CF injected template"
cat $CF_INJECTED_TEMPLATE
aws cloudformation deploy --profile deploy --template-file $CF_INJECTED_TEMPLATE --stack-name $CF_INJECTED_STACKNAME --tags appcode=nway --no-fail-on-empty-changeset 


##############################################
# integration tests
##############################################
echo "running tests"
newman run $TEST_POSTMAN_FULLPATH -e $TEST_POSTMAN_ENVIRONMENT_FULLPATH --suppress-exit-code --reporters html --reporter-html-export $TEST_POSTMAN_RESULT_FULLPATH
#upload the result to S3 (in case of success)
echo "sending test results to S3"
aws s3 --profile deploy cp $TEST_POSTMAN_RESULT_FULLPATH $S3_POSTMAN_RESULT_URI
# 1 day access to report
echo "building SNS topic message"
echo -e "Deploy result for environment $ENVIRONMENT, travis build number $TRAVIS_BUILD_NUMBER\n" > "$TEST_POSTMAN_S3_PRESIGNED_URI_FULLPATH"
echo "getting S3 test report presigned URI"
aws s3 --profile deploy presign $S3_POSTMAN_RESULT_URI --expires-in 86400 >> "$TEST_POSTMAN_S3_PRESIGNED_URI_FULLPATH"
# send top SNS topic
echo "publishing test result to topic"
aws sns --profile deploy publish --topic-arn $SNS_RESULTS_TOPIC --message file://$TEST_POSTMAN_S3_PRESIGNED_URI_FULLPATH