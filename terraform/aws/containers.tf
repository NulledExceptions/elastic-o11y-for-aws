###########################################
############### ECS Cluster ###############
###########################################

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.global_prefix}-cluster"
}

###########################################
############## ksqlDB Service #############
###########################################

data "aws_iam_policy_document" "ksqldb_server_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    sid = ""
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role_policy" "ksqldb_server_role_policy" {
  role = aws_iam_role.ksqldb_server_role.name
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_role" "ksqldb_server_role" {
  name = "ksqldb_server_role"
  assume_role_policy = data.aws_iam_policy_document.ksqldb_server_policy_document.json
}

resource "aws_iam_role_policy_attachment" "ksqldb_server_policy_attachment" {
  role = aws_iam_role.ksqldb_server_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "template_file" "ksqldb_server_definition" {
  template = file("../util/ksqldb-server.json")
  vars = {
    bootstrap_server = aws_msk_cluster.kafka_cluster.bootstrap_brokers
    ksqldb_server_image = var.ksqldb_server_image
    logs_region = data.aws_region.current.name
    global_prefix = var.global_prefix
    access_control_allow_origin = "http://${aws_s3_bucket.pacman.website_endpoint}"
    access_control_allow_methods = "OPTIONS,POST"
    access_control_allow_headers = "*"
    metricbeat_image = var.metricbeat_image
    aws_access_key_id = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    cloud_id = ec_deployment.elasticsearch.elasticsearch[0].cloud_id
    cloud_auth = "${ec_deployment.elasticsearch.elasticsearch_username}:${ec_deployment.elasticsearch.elasticsearch_password}"
  }
}

resource "aws_ecs_task_definition" "ksqldb_server_task" {
  family = "ksqldb_server_task"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "4096"  
  memory = "16384"
  execution_role_arn = aws_iam_role.ksqldb_server_role.arn
  task_role_arn = aws_iam_role.ksqldb_server_role.arn
  container_definitions = data.template_file.ksqldb_server_definition.rendered
}

resource "aws_ecs_service" "ksqldb_server_service" {
  depends_on = [
    ec_deployment.elasticsearch,
    aws_nat_gateway.default
  ]
  name = "ksqldb-server-service"
  cluster = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.ksqldb_server_task.arn
  desired_count = 1
  launch_type = "FARGATE"
  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets = aws_subnet.private_subnet[*].id
  }
}

###########################################
########### ksqlDB Auto Scaling ###########
###########################################

resource "aws_appautoscaling_target" "ksqldb_server_auto_scaling_target" {
  service_namespace = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.ksqldb_server_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = aws_iam_role.ksqldb_server_role.arn
  min_capacity = 1
  max_capacity = 8
}

resource "aws_appautoscaling_policy" "ksqldb_server_auto_scaling_up" {
  depends_on = [aws_appautoscaling_target.ksqldb_server_auto_scaling_target]
  name = "ksqldb_server_auto_scaling_up"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.ksqldb_server_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "ksqldb_server_cpu_high_alarm" {
  alarm_name = "ksqldb_server_cpu_high_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "80"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.ksqldb_server_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.ksqldb_server_auto_scaling_up.arn]
}

resource "aws_appautoscaling_policy" "ksqldb_server_auto_scaling_down" {
  depends_on = [aws_appautoscaling_target.ksqldb_server_auto_scaling_target]
  name = "ksqldb_server_auto_scaling_down"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.ksqldb_server_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "ksqldb_server_cpu_low_alarm" {
  alarm_name = "ksqldb_server_cpu_low_alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "5"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "10"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.ksqldb_server_service.name
  }
 alarm_actions = [aws_appautoscaling_policy.ksqldb_server_auto_scaling_down.arn]
}

###########################################
############ Redis Sink Service ###########
###########################################

data "aws_iam_policy_document" "redis_sink_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    sid = ""
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role_policy" "redis_sink_role_policy" {
  role = aws_iam_role.redis_sink_role.name
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_role" "redis_sink_role" {
  name = "redis_sink_role"
  assume_role_policy = data.aws_iam_policy_document.redis_sink_policy_document.json
}

resource "aws_iam_role_policy_attachment" "redis_sink_policy_attachment" {
  role = aws_iam_role.redis_sink_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "template_file" "redis_sink_definition" {
  template = file("../util/redis-sink.json")
  vars = {
    redis_sink_image = var.redis_sink_image
    bootstrap_server = aws_msk_cluster.kafka_cluster.bootstrap_brokers
    sasl_mechanism = "PLAIN"
    session_timeout = "6000"
    auto_offset_reset = "earliest"
    auto_create_topic = "true"
    num_partitions = "6"
    replication_factor = "3"
    topic_name = var.scoreboard_topic
    print_vars = "false"
    group_id = "${var.global_prefix}-${uuid()}-redis-sink"
    redis_host = aws_elasticache_replication_group.cache_server.primary_endpoint_address
    redis_port = aws_elasticache_replication_group.cache_server.port
    logs_region = data.aws_region.current.name
    metricbeat_image = var.metricbeat_image
    aws_access_key_id = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    cloud_id = ec_deployment.elasticsearch.elasticsearch[0].cloud_id
    cloud_auth = "${ec_deployment.elasticsearch.elasticsearch_username}:${ec_deployment.elasticsearch.elasticsearch_password}"
  }
}

resource "aws_ecs_task_definition" "redis_sink_task" {
  family = "redis_sink_task"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "4096"
  memory = "16384"
  execution_role_arn = aws_iam_role.redis_sink_role.arn
  task_role_arn = aws_iam_role.redis_sink_role.arn
  container_definitions = data.template_file.redis_sink_definition.rendered
}

resource "aws_ecs_service" "redis_sink_service" {
  depends_on = [
    aws_nat_gateway.default,
    aws_elasticache_replication_group.cache_server,
    ec_deployment.elasticsearch
  ]
  name = "redis-sink-service"
  cluster = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.redis_sink_task.arn
  desired_count = 1
  launch_type = "FARGATE"
  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets = aws_subnet.private_subnet[*].id
  }
}

###########################################
######### Redis Sink Auto Scaling #########
###########################################

resource "aws_appautoscaling_target" "redis_sink_auto_scaling_target" {
  service_namespace = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.redis_sink_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = aws_iam_role.redis_sink_role.arn
  min_capacity = 1
  max_capacity = 8
}

resource "aws_appautoscaling_policy" "redis_sink_auto_scaling_up" {
  depends_on = [aws_appautoscaling_target.redis_sink_auto_scaling_target]
  name = "redis_sink_auto_scaling_up"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.redis_sink_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_sink_cpu_high_alarm" {
  alarm_name = "redis_sink_cpu_high_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "80"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.redis_sink_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.redis_sink_auto_scaling_up.arn]
}

resource "aws_appautoscaling_policy" "redis_sink_auto_scaling_down" {
  depends_on = [aws_appautoscaling_target.redis_sink_auto_scaling_target]
  name = "redis_sink_auto_scaling_down"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.redis_sink_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_sink_cpu_low_alarm" {
  alarm_name = "redis_sink_cpu_low_alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "5"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "10"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.redis_sink_service.name
  }
 alarm_actions = [aws_appautoscaling_policy.redis_sink_auto_scaling_down.arn]
}

###########################################
######## Functions Metrics Service ########
###########################################

data "aws_iam_policy_document" "functions_metrics_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    sid = ""
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role_policy" "functions_metrics_role_policy" {
  role = aws_iam_role.functions_metrics_role.name
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_role" "functions_metrics_role" {
  name = "functions_metrics_role"
  assume_role_policy = data.aws_iam_policy_document.functions_metrics_policy_document.json
}

resource "aws_iam_role_policy_attachment" "functions_metrics_policy_attachment" {
  role = aws_iam_role.functions_metrics_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "template_file" "functions_metrics_definition" {
  template = file("../util/functions-metrics.json")
  vars = {
    functions_metrics_image = var.functions_metrics_image
    logs_region = data.aws_region.current.name
    aws_access_key_id = var.aws_access_key_id
    aws_secret_access_key = var.aws_secret_access_key
    cloud_id = ec_deployment.elasticsearch.elasticsearch[0].cloud_id
    cloud_auth = "${ec_deployment.elasticsearch.elasticsearch_username}:${ec_deployment.elasticsearch.elasticsearch_password}"
  }
}

resource "aws_ecs_task_definition" "functions_metrics_task" {
  family = "functions_metrics_task"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "4096"
  memory = "8192"
  execution_role_arn = aws_iam_role.functions_metrics_role.arn
  task_role_arn = aws_iam_role.functions_metrics_role.arn
  container_definitions = data.template_file.functions_metrics_definition.rendered
}

resource "aws_ecs_service" "functions_metrics_service" {
  depends_on = [
    aws_nat_gateway.default,
    ec_deployment.elasticsearch]
  name = "functions-metrics-service"
  cluster = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.functions_metrics_task.arn
  desired_count = 1
  launch_type = "FARGATE"
  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets = aws_subnet.private_subnet[*].id
  }
}

###########################################
##### Functions Metrics Auto Scaling ######
###########################################

resource "aws_appautoscaling_target" "functions_metrics_auto_scaling_target" {
  service_namespace = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.functions_metrics_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = aws_iam_role.functions_metrics_role.arn
  min_capacity = 1
  max_capacity = 2
}

resource "aws_appautoscaling_policy" "functions_metrics_auto_scaling_up" {
  depends_on = [aws_appautoscaling_target.functions_metrics_auto_scaling_target]
  name = "functions_metrics_auto_scaling_up"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.functions_metrics_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "functions_metrics_cpu_high_alarm" {
  alarm_name = "functions_metrics_cpu_high_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "80"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.functions_metrics_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.functions_metrics_auto_scaling_up.arn]
}

resource "aws_appautoscaling_policy" "functions_metrics_auto_scaling_down" {
  depends_on = [aws_appautoscaling_target.functions_metrics_auto_scaling_target]
  name = "functions_metrics_auto_scaling_down"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.functions_metrics_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "functions_metrics_cpu_low_alarm" {
  alarm_name = "functions_metrics_cpu_low_alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "5"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "10"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.functions_metrics_service.name
  }
 alarm_actions = [aws_appautoscaling_policy.functions_metrics_auto_scaling_down.arn]
}

###########################################
##### Endpoints Availability Service ######
###########################################

data "aws_iam_policy_document" "endpoints_availability_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    sid = ""
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "ecs-tasks.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role_policy" "endpoints_availability_role_policy" {
  role = aws_iam_role.endpoints_availability_role.name
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_role" "endpoints_availability_role" {
  name = "endpoints_availability_role"
  assume_role_policy = data.aws_iam_policy_document.endpoints_availability_policy_document.json
}

resource "aws_iam_role_policy_attachment" "endpoints_availability_policy_attachment" {
  role = aws_iam_role.endpoints_availability_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "template_file" "endpoints_availability_definition" {
  template = file("../util/endpoints-availability.json")
  vars = {
    endpoints_availability_image = var.endpoints_availability_image
    logs_region = data.aws_region.current.name
    pacman_welcome = "http://${aws_s3_bucket.pacman.website_endpoint}"
    event_handler_api = "${aws_api_gateway_deployment.event_handler_v1.invoke_url}${aws_api_gateway_resource.event_handler_resource.path}"
    scoreboard_api = "${aws_api_gateway_deployment.scoreboard_v1.invoke_url}${aws_api_gateway_resource.scoreboard_resource.path}"
    cloud_id = ec_deployment.elasticsearch.elasticsearch[0].cloud_id
    cloud_auth = "${ec_deployment.elasticsearch.elasticsearch_username}:${ec_deployment.elasticsearch.elasticsearch_password}"
  }
}

resource "aws_ecs_task_definition" "endpoints_availability_task" {
  family = "endpoints_availability_task"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "4096"
  memory = "8192"
  execution_role_arn = aws_iam_role.endpoints_availability_role.arn
  task_role_arn = aws_iam_role.endpoints_availability_role.arn
  container_definitions = data.template_file.endpoints_availability_definition.rendered
}

resource "aws_ecs_service" "endpoints_availability_service" {
  depends_on = [
    aws_nat_gateway.default,
    ec_deployment.elasticsearch]
  name = "endpoints_availability-service"
  cluster = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.endpoints_availability_task.arn
  desired_count = 1
  launch_type = "FARGATE"
  network_configuration {
    security_groups = [aws_security_group.ecs_tasks.id]
    subnets = aws_subnet.private_subnet[*].id
  }
}

###########################################
### Endpoints Availability Auto Scaling ###
###########################################

resource "aws_appautoscaling_target" "endpoints_availability_auto_scaling_target" {
  service_namespace = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.endpoints_availability_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn = aws_iam_role.endpoints_availability_role.arn
  min_capacity = 1
  max_capacity = 2
}

resource "aws_appautoscaling_policy" "endpoints_availability_auto_scaling_up" {
  depends_on = [aws_appautoscaling_target.endpoints_availability_auto_scaling_target]
  name = "endpoints_availability_auto_scaling_up"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.endpoints_availability_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "endpoints_availability_cpu_high_alarm" {
  alarm_name = "endpoints_availability_cpu_high_alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "80"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.endpoints_availability_service.name
  }
  alarm_actions = [aws_appautoscaling_policy.endpoints_availability_auto_scaling_up.arn]
}

resource "aws_appautoscaling_policy" "endpoints_availability_auto_scaling_down" {
  depends_on = [aws_appautoscaling_target.endpoints_availability_auto_scaling_target]
  name = "endpoints_availability_auto_scaling_down"
  service_namespace  = "ecs"
  resource_id = "service/${aws_ecs_cluster.ecs_cluster.name}/${aws_ecs_service.endpoints_availability_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown = 60
    metric_aggregation_type = "Maximum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "endpoints_availability_cpu_low_alarm" {
  alarm_name = "endpoints_availability_cpu_low_alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "5"
  metric_name = "CPUUtilization"
  namespace = "AWS/ECS"
  period = "60"
  statistic = "Average"
  threshold = "10"
  dimensions = {
    ClusterName = aws_ecs_cluster.ecs_cluster.name
    ServiceName = aws_ecs_service.endpoints_availability_service.name
  }
 alarm_actions = [aws_appautoscaling_policy.endpoints_availability_auto_scaling_down.arn]
}
