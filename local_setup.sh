#! /usr/bin/bash

# This is for WSL

# Install Ansible
sudo apt-add-repository ppa:ansible/ansible -y
sudo apt install ansible
sudo apt-get install -y python3-pip libssl-dev
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common

# Install Terraform
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt-get install terraform

# Install Packer
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository -y "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install packer