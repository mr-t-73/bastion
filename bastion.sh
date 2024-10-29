#!/bin/bash 

export AWS_PAGER=""

buildFunction()
{
	echo "Detecting Public Internet Address ..."
	PUBLIC_INTERNET_FOR_DESKTOP=$(curl https://checkip.amazonaws.com |awk '{ print $0"/32" }')
	echo "Public internet address for local Desktop Computer set to [${PUBLIC_INTERNET_FOR_DESKTOP}]"

	echo "Detecting Security Group ..."
	# SECGRP=$(aws ec2 describe-security-groups --query 'SecurityGroups[?(IpPermissions[?contains(IpRanges[].CidrIp, `10.0.0.0/16`)])].GroupId[]' --output text)
	SECGRP=$(aws ec2 describe-security-groups --query 'SecurityGroups[?(IpPermissions[?contains(IpRanges[].CidrIp, `0.0.0.0/0`)])].GroupId[]' --output text)
	echo "Setting Security Group to [${SECGRP}]"

	echo "Appending My IP address to ingress rule for security group [${SECGRP}]"
	aws ec2 authorize-security-group-ingress --group-id "${SECGRP}" --protocol tcp --port 22 --cidr "${PUBLIC_INTERNET_FOR_DESKTOP}" 

	echo "Detecting Public Subnet ..."
	PUBSUB=$(aws ec2 describe-subnets --filters "Name=tag-value,Values=PublicSubnet1" --query Subnets[].SubnetId[] --output text)
	echo "Public SubnetId set to [${PUBSUB}]"

	echo "Allocating Public Address to VPC ..."
	aws ec2 allocate-address --domain vpc --network-border-group ap-southeast-2 --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Bastion,Value=Production}]'
	echo "Complete"

	# describe-addresses looking for PublicIp
	aws ec2 describe-addresses --filters "Name=tag-key,Values=Bastion"
	# diassociate-address --public-ip
	# release-address
	echo "Creating EC2 Instance for Bastion host ..."
	aws ec2 run-instances --image-id ami-044c46b1952ad5861 --count 1 --instance-type t2.micro --key-name mrtkeypair --security-group-ids ${SECGRP} --subnet-id ${PUBSUB} --tag-specifications 'ResourceType=instance,Tags=[{Key=Bastion,Value=Production}]'
	echo "Complete"

	echo "Getting EC2 InstanceID ..."
	EC2_INSTANCE=`aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId[]' --filters "Name=tag-key,Values=Bastion" --filters Name=instance-state-name,Values=pending,running --output text`
	echo "EC2_INSTANCE set to [${EC2_INSTANCE}]"
	echo "Complete"

	echo "Creation of instance [${EC2_INSTANCE}] in progress. Please wait ..."
        echo "ec2 wait instance-running --instance-ids ${EC2_INSTANCE}"
	aws ec2 wait instance-running --instance-ids ${EC2_INSTANCE}
	echo ""
	echo "Instance is UP"
	echo ""
	echo "Detecting EC2 Instance IP Address ..."
	PUBLIC_IP=`aws ec2 describe-addresses  --filters "Name=domain,Values=vpc" --filters "Name=tag-key,Values=Bastion" --query 'Addresses[].PublicIp[]' --output text`
	echo "PUBLIC_IP set to [${PUBLIC_IP}]"
	echo "Complete"

	echo "aws ec2 associate-address --instance-id ${EC2_INSTANCE} --public-ip ${PUBLIC_IP}"
	aws ec2 associate-address --instance-id ${EC2_INSTANCE} --public-ip ${PUBLIC_IP}
	echo "Complete"

	echo "Waiting for SSH connectivity. This may take up to a minute ..."
	until ssh -q -oStrictHostKeyChecking=no -i mrtkeypair.pem ec2-user@${PUBLIC_IP} "echo"  
		do
		sleep 1
	done
	echo "SSH is UP"

	echo "Installing bind-utils on EC2 Instance ..."
	ssh -oStrictHostKeyChecking=no -i mrtkeypair.pem ec2-user@${PUBLIC_IP} "sudo yum -y -q install bind-utils"
	echo "Complete"

	echo "Detecting IP address of Postgres ..."
	RDS_IP=`ssh -oStrictHostKeyChecking=no -i ${KEY_PAIR} ec2-user@${PUBLIC_IP} "dig +short ${DNS_NAME}"`
	echo "RDS Postgres is running on IP Address [${RDS_IP}]"
	echo "Complete"

	echo "Destroy existing SSH Tunnel ..."
	TUNNEL_PID=`ps -ef -o pid |grep "[s]sh -i mrtkeypair.pem"`
	if [ ! -z "${TUNNEL_PID}" ];
		then
   		kill -9 ${TUNNEL_PID}
	fi

	echo "Create SSH Tunnel for port 5432"
	echo "ssh -i mrtkeypair.pem -fN -l ec2-user -L 5432:${RDS_IP}:5432 ${PUBLIC_IP} -v"
	ssh -i mrtkeypair.pem -fN -l ec2-user -L 5432:${RDS_IP}:5432 ${PUBLIC_IP}
	echo "Tunnel Complete"

}

destroyFunction()
{
	echo "Searching for DB Security Group ..."
	DB_SECURITY_GROUP=$(aws ec2 describe-security-groups --query 'SecurityGroups[?(IpPermissions[?contains(IpRanges[].CidrIp, `0.0.0.0/0`)])].GroupId[]' --output text)
	echo "Removing port from DB Security Group: [${DB_SECURITY_GROUP}]"
        echo "aws ec2 revoke-security-group-ingress --group-id ${DB_SECURITY_GROUP} --protocol tcp --port 22"
	aws ec2 revoke-security-group-ingress --group-id ${DB_SECURITY_GROUP} --protocol tcp --port 22
	echo "Finding AWS Public address with tag=Bastion..."
        aws ec2 describe-addresses --filters "Name=tag-key,Values=Bastion"
	PUBLIC_ADDRESS=$(aws ec2 describe-addresses --filters "Name=tag-key,Values=Bastion" --query 'Addresses[].PublicIp[]' --output text)	
        ALLOCATION_ID=$(aws ec2 describe-addresses --filters "Name=tag-key,Values=Bastion" --query 'Addresses[].AllocationId[]' --output text)
	echo ""
	echo "Disassociating AWS Public address: [${PUBLIC_ADDRESS}] ..."
        echo "aws ec2 disassociate-address --public-ip ${PUBLIC_ADDRESS}"
	aws ec2 disassociate-address --public-ip ${PUBLIC_ADDRESS}
	echo ""
	echo "Releasing AWS Public address: [${ALLOCATION_ID}] ..."
        echo "aws ec2 release-address --allocation-id ${ALLOCATION_ID}"
	aws ec2 release-address --allocation-id ${ALLOCATION_ID}
	echo ""
        echo "Finding EC2 Bastion host InstanceID ..."
        EC2_INSTANCE=`aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId[]' --filters "Name=tag-key,Values=Bastion" --filters Name=instance-state-name,Values=pending,running --output text`
        echo "EC2_INSTANCE set to [${EC2_INSTANCE}]"
        echo "Complete"
	echo ""
	echo "Terminating EC2 Instance: [${EC2_INSTANCE}] ..."
        echo "ec2 terminate-instances --instance-ids ${EC2_INSTANCE}"
        aws ec2 terminate-instances --instance-ids ${EC2_INSTANCE}
	echo ""
        echo "Removing existing SSH Tunnel ..."
        TUNNEL_PID=`ps -ef -o pid |grep "[s]sh -i mrtkeypair.pem"`
        if [ ! -z "${TUNNEL_PID}" ];
                then
                kill -9 ${TUNNEL_PID}
        fi
	echo "Bastion host removal completed successfully"
}

if [ -z $1 ]; then
	echo "Usage:"
	echo -e "\t-b .... build bastion host"
	echo -e "\t-d .... destroy bastion host"
else
	if [ "$1" = "-d" ]; then
		echo "Destroying bastion host ..."
		echo ""
		destroyFunction
	else
		echo "Building bastion host ..."
		echo ""
		buildFunction
        fi
fi
