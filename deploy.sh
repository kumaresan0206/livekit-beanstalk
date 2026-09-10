#!/bin/bash
set -e

# ==============================================================================
# LiveKit Elastic Beanstalk Deployment Coordinator Script
# ==============================================================================
# 1-Instance Standalone Architecture (Cost-Optimized, No Redis Required)
# ==============================================================================

# Default configuration variables
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
STACK_NAME="${STACK_NAME:-livekit-beanstalk-stack}"
APP_NAME="${APP_NAME:-livekit-server}"
ENV_NAME="${ENV_NAME:-livekit-production}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
MIN_INSTANCES="1"
MAX_INSTANCES="1"
CERTIFICATE_ARN="${CERTIFICATE_ARN:-}"

TIMESTAMP=$(date +%Y%m%d%H%M%S)
VERSION_LABEL="livekit-v${TIMESTAMP}"
PACKAGE_NAME="livekit-deploy-${TIMESTAMP}.zip"

echo "=========================================================================="
echo " Starting LiveKit Elastic Beanstalk Deployment Coordinator"
echo "=========================================================================="
echo "AWS Region        : ${AWS_REGION}"
echo "Stack Name        : ${STACK_NAME}"
echo "Application Name  : ${APP_NAME}"
echo "Environment Name  : ${ENV_NAME}"
echo "Instance Type     : ${INSTANCE_TYPE}"
echo "Architecture      : 1-Instance Standalone (Min: ${MIN_INSTANCES}, Max: ${MAX_INSTANCES})"
echo "Certificate ARN   : ${CERTIFICATE_ARN:-None (HTTP Only)}"
echo "Version Label     : ${VERSION_LABEL}"
echo "=========================================================================="

# ------------------------------------------------------------------------------
# Step 1: Deploy / Update Infrastructure via AWS CloudFormation
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 1/4: Deploying / Updating Infrastructure via CloudFormation..."

PARAMS="ApplicationName=${APP_NAME} EnvironmentName=${ENV_NAME} InstanceType=${INSTANCE_TYPE} MinInstances=${MIN_INSTANCES} MaxInstances=${MAX_INSTANCES}"

aws cloudformation deploy \
    --template-file template.yaml \
    --stack-name "${STACK_NAME}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides ${PARAMS} \
    --region "${AWS_REGION}"

# ------------------------------------------------------------------------------
# Step 2: Package Application Bundle (Dockerfile, docker-compose, .ebextensions)
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 2/4: Packaging application deployment bundle (${PACKAGE_NAME})..."

# Configure HTTPS listener via .ebextensions if certificate ARN is provided
if [ -n "$CERTIFICATE_ARN" ]; then
    echo "Configuring HTTPS/WSS (Port 443) listener with certificate: ${CERTIFICATE_ARN}"
    cat <<EOF > .ebextensions/02_https.config
option_settings:
  aws:elbv2:listener:443:
    ListenerEnabled: 'true'
    Protocol: HTTPS
    SSLCertificateArns: ${CERTIFICATE_ARN}
    DefaultProcess: default
EOF
fi

if command -v zip >/dev/null 2>&1; then
    zip -q -r "${PACKAGE_NAME}" \
        Dockerfile \
        docker-compose.yml \
        entrypoint.sh \
        livekit.yaml \
        .ebextensions/
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import zipfile, os
files = ['Dockerfile', 'docker-compose.yml', 'entrypoint.sh', 'livekit.yaml']
with zipfile.ZipFile('${PACKAGE_NAME}', 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        if os.path.exists(f):
            z.write(f, f)
    if os.path.exists('.ebextensions'):
        for root, _, filenames in os.walk('.ebextensions'):
            for fn in filenames:
                fp = os.path.join(root, fn)
                z.write(fp, fp)
"
else
    echo "ERROR: Neither 'zip' nor 'python3' is installed to package the application."
    exit 1
fi

# Clean up temporary https configuration file if created
rm -f .ebextensions/02_https.config

echo "Bundle created successfully: ${PACKAGE_NAME}"

# ------------------------------------------------------------------------------
# Step 3: Upload Bundle to Elastic Beanstalk S3 Storage
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 3/4: Locating Elastic Beanstalk S3 bucket and uploading bundle..."
S3_BUCKET=$(aws elasticbeanstalk create-storage-location --region "${AWS_REGION}" --query "S3Bucket" --output text)
echo "Target S3 Bucket: s3://${S3_BUCKET}"

aws s3 cp "${PACKAGE_NAME}" "s3://${S3_BUCKET}/${PACKAGE_NAME}" --region "${AWS_REGION}"

# Remove temporary local archive
rm -f "${PACKAGE_NAME}"

# ------------------------------------------------------------------------------
# Step 4: Create Application Version & Deploy to Elastic Beanstalk
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 4/4: Registering application version and updating environment..."

aws elasticbeanstalk create-application-version \
    --application-name "${APP_NAME}" \
    --version-label "${VERSION_LABEL}" \
    --source-bundle S3Bucket="${S3_BUCKET}",S3Key="${PACKAGE_NAME}" \
    --region "${AWS_REGION}" \
    --auto-create-application

echo "Triggering rolling deployment to environment '${ENV_NAME}'..."
aws elasticbeanstalk update-environment \
    --environment-name "${ENV_NAME}" \
    --version-label "${VERSION_LABEL}" \
    --region "${AWS_REGION}"

echo ""
echo "=========================================================================="
echo " Deployment successfully submitted!"
echo " Elastic Beanstalk is performing rolling updates."
echo " Container entrypoint.sh will load Secrets Manager keys on boot."
echo "=========================================================================="
