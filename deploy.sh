#!/bin/bash
set -e

# ==============================================================================
# LiveKit Elastic Beanstalk Deployment Coordinator Script
# ==============================================================================
# Deploys LiveKit WebRTC Server on Elastic Beanstalk with Existing VPC,
# Shared Custom ALB (livekit-production-alb), Auto-Validated ACM Certificate,
# and Route 53 DNS for livekit.dev.blueshirt.work.
# ==============================================================================

# Default configuration variables
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
STACK_NAME="${STACK_NAME:-livekit-beanstalk-stack}"
APP_NAME="${APP_NAME:-livekit-server}"
ENV_NAME="${ENV_NAME:-livekit-production}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
MIN_INSTANCES="${MIN_INSTANCES:-1}"
MAX_INSTANCES="${MAX_INSTANCES:-1}"
DOMAIN_NAME="${DOMAIN_NAME:-livekit.dev.blueshirt.work}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"
VPC_ID="${VPC_ID:-}"
PUBLIC_SUBNETS="${PUBLIC_SUBNETS:-}"

# Parse optional command-line flags
while [ "$#" -gt 0 ]; do
    case "$1" in
        --vpc-id) VPC_ID="$2"; shift 2 ;;
        --subnets) PUBLIC_SUBNETS="$2"; shift 2 ;;
        --hosted-zone-id) HOSTED_ZONE_ID="$2"; shift 2 ;;
        --domain-name) DOMAIN_NAME="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; shift 2 ;;
        --region) AWS_REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=========================================================================="
echo " Starting LiveKit Elastic Beanstalk Deployment Coordinator"
echo "=========================================================================="
echo "AWS Region        : ${AWS_REGION}"
echo "Stack Name        : ${STACK_NAME}"
echo "Application Name  : ${APP_NAME}"
echo "Environment Name  : ${ENV_NAME}"
echo "Domain Name       : ${DOMAIN_NAME}"
echo "Hosted Zone ID    : ${HOSTED_ZONE_ID:-Not provided}"
echo "VPC ID            : ${VPC_ID:-Not provided}"
echo "Public Subnets    : ${PUBLIC_SUBNETS:-Not provided}"
echo "Instance Type     : ${INSTANCE_TYPE}"
echo "Architecture      : Standalone (Min: ${MIN_INSTANCES}, Max: ${MAX_INSTANCES})"
echo "=========================================================================="

# Validation for required networking parameters
if [ -z "$VPC_ID" ] || [ -z "$PUBLIC_SUBNETS" ] || [ -z "$HOSTED_ZONE_ID" ]; then
    echo ""
    echo "ERROR: Missing required parameters."
    echo "Please export environment variables or provide CLI flags:"
    echo "  export VPC_ID='vpc-xxxxxxxx'"
    echo "  export PUBLIC_SUBNETS='subnet-xxxxxxxx,subnet-yyyyyyyy'"
    echo "  export HOSTED_ZONE_ID='Zxxxxxxxxxxxx'"
    echo ""
    echo "Usage via CLI flags:"
    echo "  ./deploy.sh --vpc-id vpc-xxxxxxxx --subnets 'subnet-xxxx,subnet-yyyy' --hosted-zone-id Zxxxxxxxx"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d%H%M%S)
VERSION_LABEL="livekit-v${TIMESTAMP}"
PACKAGE_NAME="livekit-deploy-${TIMESTAMP}.zip"

# ------------------------------------------------------------------------------
# Step 1: Deploy / Update Infrastructure via AWS CloudFormation
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 1/4: Deploying / Updating Infrastructure via CloudFormation..."

aws cloudformation deploy \
    --template-file template.yaml \
    --stack-name "${STACK_NAME}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ApplicationName="${APP_NAME}" \
        EnvironmentName="${ENV_NAME}" \
        InstanceType="${INSTANCE_TYPE}" \
        MinInstances="${MIN_INSTANCES}" \
        MaxInstances="${MAX_INSTANCES}" \
        VpcId="${VPC_ID}" \
        PublicSubnets="${PUBLIC_SUBNETS}" \
        HostedZoneId="${HOSTED_ZONE_ID}" \
        DomainName="${DOMAIN_NAME}" \
    --region "${AWS_REGION}"

# ------------------------------------------------------------------------------
# Step 2: Package Application Bundle (Dockerfile, docker-compose, .ebextensions)
# ------------------------------------------------------------------------------
echo ""
echo ">> Step 2/4: Packaging application deployment bundle (${PACKAGE_NAME})..."

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
echo " URL: https://${DOMAIN_NAME}"
echo " Elastic Beanstalk is performing rolling updates."
echo " Container entrypoint.sh will load Secrets Manager keys on boot."
echo "=========================================================================="
