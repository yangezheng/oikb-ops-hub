# "I need to know when it breaks before the support team does."
#
# Two alerts, both about the ABSENCE of a success, not the presence of an error:
#
#   1. sync heartbeat: the sync job prints "OIKB_SYNC_OK instance=<id>" after a
#      run in which oikb reported zero errors. If no such line arrived for
#      max_staleness (45 min = three missed runs), alert. Every silent failure
#      looks the same to this rule: job not scheduled, image pull failed,
#      GitHub token revoked, Open WebUI login failed, sync stuck or erroring.
#      A "notify on error" hook cannot report its own death.
#
#   2. availability: /health is requested from three regions every 5 minutes.
#
# Both mail the platform admin and send a second mail when they recover.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "sync_heartbeat" {
  name                 = "alert-${local.instance}-sync-stale"
  resource_group_name  = azurerm_resource_group.opco.name
  location             = azurerm_resource_group.opco.location
  description          = "Knowledge base '${var.kb_name}' of ${local.instance} has not been synced successfully for ${var.max_staleness}. Check the executions of job-${local.instance}-sync."
  severity             = 1
  scopes               = [local.platform.log_analytics_workspace_id]
  evaluation_frequency = "PT15M"
  window_duration      = var.max_staleness
  tags                 = local.tags

  criteria {
    query                   = <<-KQL
      ContainerAppConsoleLogs_CL
      | where Log_s contains "OIKB_SYNC_OK instance=${local.instance} "
    KQL
    time_aggregation_method = "Count"
    operator                = "LessThan"
    threshold               = 1

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  # The log table is created by the first log line, after this rule.
  skip_query_validation = true

  action {
    action_groups = [local.platform.action_group_id]
  }
}

locals {
  # West Europe, North Europe, France Central
  web_test_locations = ["emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge"]
}

# Web tests have to sit next to their Application Insights component, so
# these two resources are created in the platform resource group.
resource "azurerm_application_insights_standard_web_test" "health" {
  name                    = "webtest-${local.instance}-health"
  location                = local.platform.location
  resource_group_name     = local.platform.resource_group_name
  application_insights_id = local.platform.application_insights_id
  description             = "Open WebUI of ${local.instance} is reachable"
  geo_locations           = local.web_test_locations
  frequency               = 300
  timeout                 = 30
  enabled                 = true
  retry_enabled           = true

  request {
    url = "${local.url}/health"
  }

  validation_rules {
    expected_status_code        = 200
    ssl_check_enabled           = true
    ssl_cert_remaining_lifetime = 7
  }

  tags = merge(local.tags, {
    "hidden-link:${local.platform.application_insights_id}" = "Resource"
  })
}

resource "azurerm_monitor_metric_alert" "health" {
  name                = "alert-${local.instance}-unreachable"
  resource_group_name = local.platform.resource_group_name
  description         = "Open WebUI at ${local.url} is not reachable."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  auto_mitigate       = true
  tags                = local.tags

  scopes = [
    azurerm_application_insights_standard_web_test.health.id,
    local.platform.application_insights_id,
  ]

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.health.id
    component_id          = local.platform.application_insights_id
    failed_location_count = 2
  }

  action {
    action_group_id = local.platform.action_group_id
  }
}
