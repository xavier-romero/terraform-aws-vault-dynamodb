#!/bin/bash

waitforurl() {
    timeout -s TERM 45 bash -c \
    'while [[ "$(curl -s -o /dev/null -L -w ''%%{http_code}'' ${0})" != "200" ]]; do sleep 2; done'
}

# Detect package management system.
YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)

user_rhel() {
  # RHEL user setup
  sudo /usr/sbin/groupadd --force --system $2

  if ! getent passwd $1 >/dev/null ; then
    sudo /usr/sbin/adduser \
      --system \
      --gid $2 \
      --home $3 \
      --no-create-home \
      --comment "$4" \
      --shell /bin/false \
      $1  >/dev/null
  fi
}

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $2 >/dev/null
  then
    sudo addgroup --system $2 >/dev/null
  fi

  if ! getent passwd $1 >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $2 \
      --home $3 \
      --no-create-home \
      --gecos "$4" \
      --shell /bin/false \
      $1  >/dev/null
  fi
}

# Found errors due to network unavailable when doing packet install. Let's wait a bit.
sleep 120

if [[ ! -z $${YUM} ]]; then
  echo "Setting up user vault for amazon_linux"
  user_rhel "vault" "vault" "/etc/vault" "Hashicorp vault user"

  yum update -y
  yum install jq git -y
  curl -s https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/${arch_version}/latest/amazon-cloudwatch-agent.rpm --output /tmp/amazon-cloudwatch-agent.rpm
  rpm -U /tmp/amazon-cloudwatch-agent.rpm

elif [[ ! -z $${APT_GET} ]]; then
  echo "Setting up user vault for Debian/Ubuntu"
  user_ubuntu "vault" "vault" "/etc/vault" "Hashicorp vault user"

  apt-get update -y
  apt-get install jq git -y
  curl -s https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/${arch_version}/latest/amazon-cloudwatch-agent.deb --output /tmp/amazon-cloudwatch-agent.deb
  dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
else
  echo "users not created due to OS detection failure"
  exit 1;
fi

INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id -s)
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --instance-ids $INSTANCE_ID --region eu-west-1 | jq -r .AutoScalingInstances[0].AutoScalingGroupName)

echo "Amazon cloudwatch Agent"

cat << EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "metrics_collection_interval": 300,
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
        "force_flush_interval": 15,
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/vault_audit.log",
                        "log_group_name": "${environment}-${app_name}",
                        "log_stream_name": "vaultaudit-$INSTANCE_ID",
                        "timezone": "Local"
                    },
                    {
                        "file_path": "/var/log/secure",
                        "log_group_name": "${environment}-${app_name}",
                        "log_stream_name": "secure-$INSTANCE_ID",
                        "timezone": "Local"
                    },
                    {
                        "file_path": "/var/log/messages",
                        "log_group_name": "${environment}-${app_name}",
                        "log_stream_name": "messages-$INSTANCE_ID",
                        "timezone": "Local"
                    }
                ]
            }
        }
    },
  "metrics": {
    "metrics_collected": {
      "disk": {
        "metrics_collection_interval": 600,
        "resources": [
          "/"
        ],
        "measurement": [
          {"name": "disk_free", "rename": "DISK_FREE", "unit": "Gigabytes"}
        ]
      },
      "mem": {
        "metrics_collection_interval": 600,
        "measurement": [
          {"name": "mem_free", "rename": "MEM_FREE", "unit": "Megabytes"},
          {"name": "mem_total", "rename": "MEM_TOTAL", "unit": "Megabytes"},
          {"name": "mem_used", "rename": "MEM_USED", "unit": "Megabytes"}
        ]
      }
    },
    "append_dimensions": {
          "AutoScalingGroupName": "$ASG_NAME",
          "InstanceId": "$INSTANCE_ID"
    },
    "aggregation_dimensions" : [
            ["AutoScalingGroupName"],
            ["InstanceId"],
            []
        ]
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
systemctl enable amazon-cloudwatch-agent.service

curl --silent --output /tmp/vault.zip ${vault_url}
unzip -o /tmp/vault.zip -d /sbin/
chmod 0755 /sbin/vault
mkdir -pm 0755 /etc/vault
chown vault:vault /etc/vault


cat << EOF > /lib/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault/vault.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/sbin/vault server -config=/etc/vault/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StartLimitInterval=60
StartLimitIntervalSec=60
StartLimitBurst=3
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF


openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /etc/vault/vault_ssl.key -out /etc/vault/vault_ssl.crt -subj "/CN=vault.local"

cat << EOF > /etc/vault/vault.hcl
storage "dynamodb" {
  region     = "${aws_region}"
  table      = "${environment}-${app_name}"
}

listener "tcp" {
  address = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file = "/etc/vault/vault_ssl.crt"
  tls_key_file = "/etc/vault/vault_ssl.key"
}

listener "tcp" {
  address = "127.0.0.1:8203"
  tls_disable = 1
}

seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key}"
}
api_addr = "https://0.0.0.0:8203"
cluster_addr = "https://0.0.0.0:8201"
ui=true
plugin_directory = "/etc/vault/plugins"

EOF

# install iden3 plugin
mkdir /etc/vault/plugins
cd /tmp && wget https://github.com/iden3/vault-plugin-secrets-iden3/releases/download/v0.0.6/vault-plugin-secrets-iden3_0.0.6_linux_amd64.tar.gz
tar -xzf vault-plugin-secrets-iden3_0.0.6_linux_amd64.tar.gz
mv vault-plugin-secrets-iden3 /etc/vault/plugins/

chown -R vault:vault /etc/vault
chmod -R 0644 /etc/vault/*
chmod +x /etc/vault/plugins
# touch /var/log/vault_audit.log
# chown vault:vault /var/log/vault_audit.log

cat << EOF > /etc/profile.d/vault.sh
export VAULT_ADDR=https://0.0.0.0:8200
export VAULT_SKIP_VERIFY=true
EOF
systemctl daemon-reload
systemctl enable vault
systemctl start vault

# export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_ADDR=https://0.0.0.0:8200
export VAULT_SKIP_VERIFY=true
echo "waiting vault boot"
waitforurl https://127.0.0.1:8200/v1/sys/seal-status
echo "vault is available"
STATUS=$(vault status -format=json)
if [ "$(echo $STATUS | jq .initialized)" == "false" ]
then
  echo "initializing vault"
  INIT=$(vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
  ROOT_TOKEN="$(echo $INIT | jq .root_token -r)"
  RECOVERY_KEY="$(echo $INIT | jq .recovery_keys_b64[0] -r)" > /dev/null 2>&1
  STATUS2=$(vault status -format=json )
  if [ "$(echo $STATUS2 | jq .sealed)" == "false" ]
  then
    vault login $ROOT_TOKEN
    vault secrets enable -path=secret/ kv-v2
    echo "vault setup completed"

    export VAULT_TOKEN=$ROOT_TOKEN
    # echo "Setting Audit file"
    # vault audit enable file file_path=/var/log/vault_audit.log
    vault audit disable file/

    vault plugin register -sha256=0156a4521508edc5f60fab8c13a6f08dd45668644aaf2d18600e713c3791db14 vault-plugin-secrets-iden3
    vault plugin reload -plugin=vault-plugin-secrets-iden3
    vault secrets enable -path=iden3 vault-plugin-secrets-i

    cat << EOF > /tmp/admin.hcl
path "*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
      # echo "Creating Admin Policy"
      # vault policy write admin /tmp/admin.hcl
      # echo "Enabling userpass"
      # vault auth enable userpass
      # echo "setting admin user"
      PASS=$(openssl rand -base64 18)
      # echo "setting vault root username and passwd"
      # vault write auth/userpass/users/root password="$PASS" policies=admin,default

      echo "Saving root token on ssm:///${app_name}/${environment}/root/token"
      aws ssm put-parameter --name '/${app_name}/${environment}/root/token' --value "$ROOT_TOKEN" --type SecureString --region ${aws_region} --overwrite > /dev/null 2>&1
      echo "Saving root password on ssm:///${app_name}/${environment}/root/pass"
      aws ssm put-parameter --name '/${app_name}/${environment}/root/pass'  --value "$PASS"  --type SecureString --region ${aws_region} --overwrite > /dev/null 2>&1

      cd && curl https://dl.google.com/go/go1.18.2.linux-amd64.tar.gz -s -o go.tar.gz
      rm -rf /usr/local/go && tar -C /usr/local -xzf go.tar.gz
      export PATH=$PATH:/usr/local/go/bin
      cd && git clone https://github.com/ConsenSys/quorum-hashicorp-vault-plugin.git
      cd quorum-hashicorp-vault-plugin && make gobuild
      MY_SHA256=$(sha256sum build/bin/quorum-hashicorp-vault-plugin | cut -f1 -d' ')
      mv -f build/bin/quorum-hashicorp-vault-plugin /etc/vault/plugins/
      chown vault:vault /etc/vault/plugins/quorum-hashicorp-vault-plugin
      vault plugin register -sha256=$MY_SHA256 secret quorum-hashicorp-vault-plugin
  else
    echo "Error on vault setup"
    echo $STATUS2
  fi

else
  echo "vault already initialized"
fi
