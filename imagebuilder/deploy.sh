#!/bin/bash
# Deploy EC2 Image Builder Pipeline for EKS hardended image.
set -e

#Kubernetes Verion
k8sVersion="1.27"

## The deployment is driven by the following options:
usage() {
    echo "Usage: "
    echo "deploy.sh -v <version>"
    echo "Where "
    echo "-v <version>: version of pipeline, increment to update in place. default 1.0.0"
    echo "-h: Print this help"
}

#parse options
while getopts "v:h" opt; do
  case $opt in
    v)
        version=${OPTARG}
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

#arguments required
if [ -z "${version}" ];
  then
    echo "no version specified. defaulting to Version=1.0.0"
    version="1.0.0"
fi

echo "Getting latest image details..."

#get latest image id
imageId=$(aws ssm get-parameters --name /aws/service/eks/optimized-ami/${k8sVersion}/amazon-linux-2/recommended/image_id --output text --query 'Parameters[].[Value]')
imageName=$(aws ec2 describe-images --image-id ${imageId} --output text --query 'Images[].[Name]')
cfnParams="AMI=${imageId} ImageName=${imageName} Version=${version}"

echo "Latest image is ${imageName} (${imageId})"

echo "Creating Cloudformation service role..."

policyArns=("arn:aws:iam::aws:policy/IAMFullAccess" "arn:aws:iam::aws:policy/AmazonS3FullAccess" "arn:aws:iam::aws:policy/AWSImageBuilderFullAccess" "arn:aws:iam::aws:policy/AWSKeyManagementServicePowerUser")

if customPolicyArn=$(aws iam create-policy --policy-name kmsPutKeyPolicy --policy-document file://./policy.json --output text --query 'Policy.[Arn]'); then
    echo "IAM KMS policy created"
else
    customPolicyArn=$(aws iam list-policies --output text --query "Policies[?PolicyName=='kmsPutKeyPolicy'].[Arn]")
    echo "IAM KMS policy found"
fi

policyArns+=($customPolicyArn)

if roleArn=$(aws iam get-role --role-name ccs-eks-golden-cloudformation-svc-role --output text --query 'Role.[Arn]'); then
    #ensure policies are attached
    for arn in ${policyArns[@]}; do
        aws iam attach-role-policy --role-name ccs-eks-golden-cloudformation-svc-role --policy-arn $arn
    done
    echo "Role exists, policies attached"
else
    #create role
    roleArn=$(aws iam create-role --role-name ccs-eks-golden-cloudformation-svc-role --assume-role-policy-document file://./role.json --output text --query 'Role.[Arn]')
    #attach policies
    for arn in ${policyArns[@]}; do
        aws iam attach-role-policy --role-name ccs-eks-golden-cloudformation-svc-role --policy-arn $arn
    done
    
    echo "Role created and policies attached"
fi

echo "Deploying Cloudformation package..."
#deploy package
if aws cloudformation deploy --template-file imageBuilder.yaml \
    --stack-name ccs-eks-gold-imageBuilder --parameter-overrides $cfnParams \
    --capabilities CAPABILITY_IAM \
    --role-arn $roleArn; then
    echo "CloudFormation successfully deployed the package"
else
    echo "Failed deploying CloudFormation package"
    exit 1
fi 

echo "Getting scripts bucket..."
scriptsBucket=$(aws cloudformation list-exports --output text  --query "Exports[?Name=='ScriptsBucket'].[Value]")

echo "Syncing scripts"
if aws s3 sync ../scripts s3://$scriptsBucket; then
    echo "S3 sync sucessful"
else
    echo "Failed syncing S3 bucket"
    exit 1
fi  

echo "Done"
