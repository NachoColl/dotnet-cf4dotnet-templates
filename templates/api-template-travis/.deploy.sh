#!/bin/bash

set -e


#################
# ARGUMENTS     #
#################

# test, staging or prod
ENVIRONMENT=$1

# the project file name (e.g. MyApiProject)
CSPROJ=$2

# the test project file name (e.g. MyApiProjectTests)
CSPROJ_TEST=$3

#################
# VARS          #
#################

# csproj files
PROJECT_FILE=$(echo $TRAVIS_BUILD_DIR/src/$CSPROJ.csproj)
PROJECT_FILE_TEST=$(echo $TRAVIS_BUILD_DIR/test/nwayapi.Tests.csproj)

# testing
TEST_PROJECT_FILE=$(echo $TRAVIS_BUILD_DIR/test/nwayapi.Tests.csproj)
TEST_POSTMAN_PATH=$(echo $TRAVIS_BUILD_DIR/test/postman)
TEST_POSTMAN_FULLPATH=$(echo $TEST_POSTMAN_PATH/nway-api.postman_collection.json)
TEST_POSTMAN_ENVIRONMENT_FULLPATH=$(echo $TEST_POSTMAN_PATH/nway_${ENVIRONMENT}_environment.postman_environment.json)
TEST_POSTMAN_RESULT_FULLPATH=$(echo $TEST_POSTMAN_PATH/result-$TRAVIS_BUILD_NUMBER.html)
TEST_POSTMAN_S3_RESULT_FILENAME=$(echo result-$TRAVIS_BUILD_NUMBER.html)
TEST_POSTMAN_S3_PRESIGNED_URI_FULLPATH=$(echo $TEST_POSTMAN_PATH/result-uri.txt)
# artifact
ARTIFACT_PATH=$(echo $TRAVIS_BUILD_DIR/dist/)
ARTIFACT_BASEFILENAME=$(echo $ENVIRONMENT)
ARTIFACT_FILENAME=$(echo $ENVIRONMENT-$TRAVIS_BUILD_NUMBER.zip)
ARTIFACT_FULLPATH=$(echo $TRAVIS_BUILD_DIR/dist/$ARTIFACT_FILENAME)
# cloudformation injection project
INJECTION_DLL_FILE=$(echo $ARTIFACT_PATH/nwayapi.dll)
INJECTION_FILESPATH=$(echo $TRAVIS_BUILD_DIR/deploy)
INJECTION_PROJECT_FILE=$(echo $TRAVIS_BUILD_DIR/deploy/injection.csproj)
# AWS related:
AWS_ACCOUNT=$(case $ENVIRONMENT in test) echo $AWS_ACCOUNT_test ;; staging) echo $AWS_ACCOUNT_staging ;; prod) echo $AWS_ACCOUNT_prod ;; esac)
AWS_ROLE=$(echo arn:aws:iam::$AWS_ACCOUNT:role/serverless-deployments)
# local cloudformation templates
CF_DATABASE_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/deploy/dynamodb.yml)
CF_BASE_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/deploy/sam-base.yml)
CF_INJECTED_TEMPLATE=$(echo $TRAVIS_BUILD_DIR/deploy/sam-$ENVIRONMENT.yml)
# S3 artifacts
S3_BUCKET=$(echo deployments-$AWS_ACCOUNT)
S3_ARTIFACT_BUCKET=$(echo s3://$S3_BUCKET/api)
S3_ARTIFACT_URI=$(echo $S3_ARTIFACT_BUCKET/$ARTIFACT_FILENAME)
S3_POSTMAN_RESULT_URI=$(echo s3://$S3_BUCKET/api/$TEST_POSTMAN_S3_RESULT_FILENAME)
# SNS
SNS_RESULTS_TOPIC=$(echo arn:aws:sns:us-east-1:$AWS_ACCOUNT:nway-deployments)
# AWS cloudformation STACKS
CF_DATABASE_STACKNAME=$(echo nway-api-dynamodb)
CF_BASE_STACKNAME=$(echo nway-api)
CF_INJECTED_STACKNAME=$(echo nway-api-$ENVIRONMENT)


###############################################
# scripting
###############################################
echo "deploying to $AWS_ACCOUNT account using $AWS_ROLE role"
# create AWS .config credentials file 
echo "setting credentials"
aws configure set default.aws_access_key_id $AWS_ACCESS_KEY_ID
aws configure set default.aws_secret_access_key $AWS_SECRET_ACCESS_KEY
aws configure set default.region $AWS_DEFAULT_REGION
aws configure set profile.deploy.role_arn $AWS_ROLE
aws configure set profile.deploy.source_profile default

##############################################
# create artifact and send to S3
##############################################

echo "creating artifact"
# define code constants
sed -i -e "s/RELEASE/${ENVIRONMENT^^}/g" $PROJECT_FILE
sed -i -e "s/RELEASE/${ENVIRONMENT^^}/g" $LIBRARY_PROJECT_FILE
# publish dotnet code
dotnet publish $PROJECT_FILE -o $ARTIFACT_PATH --framework netcoreapp2.0 --runtime linux-x64 -c Release
# package code
echo "packaging artifact"
zip -j $ARTIFACT_FULLPATH $ARTIFACT_PATH/* 
# upload code to S3 deployment bucket
echo "copying artifact to s3"
aws s3 --profile deploy cp $ARTIFACT_FULLPATH $S3_ARTIFACT_URI


##############################################
# deploy CF dynamodb template
##############################################

# just deploy DynamoDB on test environment. PROD account (staging + prod) already has a legacy version.
if [ "$ENVIRONMENT" == "test" ]; then
    echo "deploying dynamodb CF"
    aws cloudformation deploy --profile deploy --template-file $CF_DATABASE_TEMPLATE --stack-name $CF_DATABASE_STACKNAME --tags appcode=nway --no-fail-on-empty-changeset 
fi

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