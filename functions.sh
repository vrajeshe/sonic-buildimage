diff --git a/dockers/docker-fpm-frr/docker_init.sh b/dockers/docker-fpm-frr/docker_init.sh
index b66736e12..f3ecb2d6f 100755
--- a/dockers/docker-fpm-frr/docker_init.sh
+++ b/dockers/docker-fpm-frr/docker_init.sh
@@ -67,8 +67,12 @@ elif [ "$CONFIG_TYPE" == "split-unified" ]; then
     write_default_zebra_config /etc/frr/frr.conf
 elif [ -z "$CONFIG_TYPE" ] || [ "$CONFIG_TYPE" == "unified" ] || [ "$CONFIG_TYPE" == "separated" ]; then
     if [ "$CONFIG_TYPE" == "separated" ]; then
-        logger -t docker-fpm-frr -p user.warning "Config Type 'separated' is deprecated. The system will use unified mode instead."
-        echo "Config Type separated is not supported"
+        logger -t docker-fpm-frr -p user.warning "Config Type 'separated' is deprecated. Migrating to 'unified'."
+        # Persist the migration in CONFIG_DB so the rest of the system (tests,
+        # bgpcfgd, sonic-utilities) agrees with the runtime layout.
+        sonic-db-cli CONFIG_DB hset 'DEVICE_METADATA|localhost' docker_routing_config_mode unified >/dev/null 2>&1 || true
+        CONFIG_TYPE=unified
+        FRR_VARS=$(echo "$FRR_VARS" | jq -c '.docker_routing_config_mode = "unified"')
     fi
     MGMT_FRAMEWORK_CONFIG=$(echo $FRR_VARS | jq -r '.frr_mgmt_framework_config')
     if [ -n "$MGMT_FRAMEWORK_CONFIG" ] && [ "$MGMT_FRAMEWORK_CONFIG" != "false" ]; then
@@ -82,6 +86,7 @@ elif [ -z "$CONFIG_TYPE" ] || [ "$CONFIG_TYPE" == "unified" ] || [ "$CONFIG_TYPE
         CFGGEN_PARAMS=" \
             -d \
             -y /etc/sonic/constants.yml \
+            -T /usr/local/sonic/frrcfgd \
             -t /usr/share/sonic/templates/gen_frr.conf.j2,/etc/frr/frr.conf \
         "
     fi
diff --git a/dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2 b/dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2
index 7bcffa777..85182e543 100644
--- a/dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2
+++ b/dockers/docker-fpm-frr/frr/bgpd/bgpd.conf.j2
@@ -15,10 +15,10 @@
 agentx
 !
 {% if DEVICE_METADATA['localhost']['type'] == "SpineChassisFrontendRouter" %}
-{%  include "bgpd/bgpd.spine_chassis_frontend_router.conf.j2" %}
+{%  include "bgpd.spine_chassis_frontend_router.conf.j2" %}
 {% endif %}
 !
-{% include "bgpd/bgpd.main.conf.j2" %}
+{% include "bgpd.main.conf.j2" %}
 !
 ! end of template: bgpd/bgpd.conf.j2
 !
diff --git a/dockers/docker-fpm-frr/frr/gen_frr.conf.j2 b/dockers/docker-fpm-frr/frr/gen_frr.conf.j2
index bd197480f..181437da0 100644
--- a/dockers/docker-fpm-frr/frr/gen_frr.conf.j2
+++ b/dockers/docker-fpm-frr/frr/gen_frr.conf.j2
@@ -1,13 +1,5 @@
-{# Note: This template replaces the old frr.conf.j2 which included specific sub-components directly.
-     The new approach includes the main daemon config files (zebra.conf.j2, staticd.conf.j2, bgpd.conf.j2)
-     which in turn include the same sub-components. This provides equivalent configuration with
-     better modularity. Each daemon config includes common/daemons.common.conf.j2, which is safe
-     as it contains daemon-agnostic configuration. #}
 {% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
     {% include "/usr/local/sonic/frrcfgd/frr.conf.j2" %}
 {% else %}
-    {% include "/usr/share/sonic/templates/zebra/zebra.conf.j2" %}
-    {% include "/usr/share/sonic/templates/staticd/staticd.conf.j2" %}
-    {% include "/usr/share/sonic/templates/bgpd/bgpd.conf.j2" %}
-    {% include "/usr/share/sonic/templates/sharpd/sharpd.conf.j2" %}
+    {% include "/usr/share/sonic/templates/frr.conf.j2" %}
 {% endif %}
diff --git a/dockers/docker-fpm-frr/frr/staticd/staticd.conf.j2 b/dockers/docker-fpm-frr/frr/staticd/staticd.conf.j2
index 5eb26caab..6d00ac660 100644
--- a/dockers/docker-fpm-frr/frr/staticd/staticd.conf.j2
+++ b/dockers/docker-fpm-frr/frr/staticd/staticd.conf.j2
@@ -8,5 +8,5 @@
 !
 {% include "common/daemons.common.conf.j2" %}
 !
-{% include "staticd/staticd.loopback_route.conf.j2" %}
+{% include "staticd.loopback_route.conf.j2" %}
 !
diff --git a/dockers/docker-fpm-frr/frr/zebra/zebra.conf.j2 b/dockers/docker-fpm-frr/frr/zebra/zebra.conf.j2
index 95f969cbf..13b47b882 100644
--- a/dockers/docker-fpm-frr/frr/zebra/zebra.conf.j2
+++ b/dockers/docker-fpm-frr/frr/zebra/zebra.conf.j2
@@ -31,5 +31,5 @@ zebra nexthop-group keep 1
 !
 {% include "common/daemons.common.conf.j2" %}
 !
-{% include "zebra/zebra.interfaces.conf.j2" %}
+{% include "zebra.interfaces.conf.j2" %}
 !
