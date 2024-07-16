# Infrastructure for the Yandex Cloud Managed Service for Apache Kafka®, Managed Service for MySQL, and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/data-transfer/tutorials/mkf-to-mmy
# EN: https://yandex.cloud/en/docs/data-transfer/tutorials/mkf-to-mmy
#
# Configure the parameters of the source and target clusters:

locals {
  # Source Managed Service for Apache Kafka® cluster settings:
  source_kf_version    = "" # Desired version of Apache Kafka®. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-kafka/.
  source_user_password = "" # Apache Kafka® user's password

  # Target Managed Service for MySQL cluster settings:
  target_mysql_version = "" # Desired version of MySQL. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-mysql/.
  target_user_password = "" # MySQL user's password

  # Specify these settings ONLY AFTER the clusters are created. Then run "terraform apply" command again.
  # You should set up endpoints using the GUI to obtain their IDs
  source_endpoint_id = "" # Set the source endpoint ID
  transfer_enabled   = 0  # Set to 1 to enable the transfer

  # The following settings are predefined. Change them only if necessary.
  network_name         = "network"                  # Name of the network
  subnet_name          = "subnet-a"                 # Name of the subnet
  source_cluster_name  = "kafka-cluster"            # Name of the Apache Kafka® cluster
  source_topic         = "sensors"                  # Name of the Apache Kafka® topic
  source_username      = "mkf-user"                 # Username of the Apache Kafka® cluster
  target_cluster_name  = "mysql-cluster"            # Name of the MySQL cluster
  target_db_name       = "db1"                      # Name of the MySQL database
  target_username      = "mmy-user"                 # Username of the MySQL cluster
  target_endpoint_name = "mmy-target-tf"            # Name of the target endpoint for the Managed Service for MySQL cluster
  transfer_name        = "transfer-from-mkf-to-mmy" # Name of the transfer from the Managed Service for Apache Kafka® to the Managed Service for MySQL
}

# Network infrastructure

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for Apache Kafka® and Managed Service for MySQL clusters"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.1.0.0/16"]
}

resource "yandex_vpc_security_group" "clusters-security-group" {
  description = "Security group for the Managed Service for Apache Kafka® and Managed Service for MySQL clusters"
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allow connections to the Managed Service for Apache Kafka® cluster from the Internet"
    protocol       = "TCP"
    port           = 9091
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow connections to the Managed Service for MySQL cluster from the Internet"
    protocol       = "TCP"
    port           = 3306
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "The rule allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Managed Service for Apache Kafka® cluster

resource "yandex_mdb_kafka_cluster" "kafka-cluster" {
  description        = "Managed Service for Apache Kafka® cluster"
  name               = local.source_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.clusters-security-group.id]

  config {
    brokers_count    = 1
    version          = local.source_kf_version
    zones            = ["ru-central1-a"]
    assign_public_ip = true # Required for connection from the Internet
    kafka {
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
        disk_type_id       = "network-hdd"
        disk_size          = 10 # GB
      }
    }
  }

  depends_on = [
    yandex_vpc_subnet.subnet-a
  ]
}

# Topic of the Managed Service for Apache Kafka® cluster
resource "yandex_mdb_kafka_topic" "sensors" {
  cluster_id         = yandex_mdb_kafka_cluster.kafka-cluster.id
  name               = local.source_topic
  partitions         = 2
  replication_factor = 1
}

# User of the Managed Service for Apache Kafka® cluster
resource "yandex_mdb_kafka_user" "mkf-user" {
  cluster_id = yandex_mdb_kafka_cluster.kafka-cluster.id
  name       = local.source_username
  password   = local.source_user_password
  permission {
    topic_name = yandex_mdb_kafka_topic.sensors.name
    role       = "ACCESS_ROLE_CONSUMER"
  }
  permission {
    topic_name = yandex_mdb_kafka_topic.sensors.name
    role       = "ACCESS_ROLE_PRODUCER"
  }
}

# Infrastructure for the Managed Service for MySQL cluster

resource "yandex_mdb_mysql_cluster" "mysql-cluster" {
  description        = "Managed Service for MySQL cluster"
  name               = local.target_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  version            = local.target_mysql_version
  security_group_ids = [yandex_vpc_security_group.clusters-security-group.id]

  resources {
    resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
    disk_type_id       = "network-hdd"
    disk_size          = 10 # GB
  }

  host {
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.subnet-a.id
    assign_public_ip = true # Required for connection from Internet
  }
}

# Database of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_database" "db1" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.target_db_name
}

# User of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_user" "user1" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.target_username
  password   = local.target_user_password
  permission {
    database_name = yandex_mdb_mysql_database.db1.name
    roles         = ["ALL"]
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "mmy_target" {
  count       = local.transfer_enabled
  description = "Target endpoint for the Managed Service for MySQL cluster"
  name        = local.target_endpoint_name
  settings {
    mysql_target {
      connection {
        mdb_cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
      }
      database = yandex_mdb_mysql_database.db1.name
      user     = yandex_mdb_mysql_user.user1.name
      password {
        raw = local.target_user_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "mkf-mmy-transfer" {
  description = "Transfer from the Managed Service for Apache Kafka® to the Managed Service for MySQL"
  count       = local.transfer_enabled
  name        = local.transfer_name
  source_id   = local.source_endpoint_id
  target_id   = yandex_datatransfer_endpoint.mmy_target[count.index].id
  type        = "INCREMENT_ONLY" # Replication data
}
