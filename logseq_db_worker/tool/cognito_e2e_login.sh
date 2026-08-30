#!/bin/sh
set -eu

exec /usr/bin/curl \
  --silent \
  --show-error \
  --fail-with-body \
  --connect-timeout 15 \
  --max-time 60 \
  --header 'content-type: application/x-amz-json-1.1' \
  --header 'x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth' \
  --data-binary @- \
  'https://cognito-idp.us-east-1.amazonaws.com/'
