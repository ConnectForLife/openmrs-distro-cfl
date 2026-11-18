#!/bin/bash -eux

DB_CREATE_TABLES=${DB_CREATE_TABLES:-false}
DB_AUTO_UPDATE=${DB_AUTO_UPDATE:-false}
MODULE_WEB_ADMIN=${MODULE_WEB_ADMIN:-true}
DEBUG=${DEBUG:-false}
DEV_MODE_MODULES=${DEV_MODE_MODULES:-"messages"}
DB_SSL_MODE=${DB_SSL_MODE:-REQUIRED}
case "$DB_SSL_MODE" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY) ;;
  *) echo "DB_SSL_MODE must be DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY, got: ${DB_SSL_MODE}"; exit 1 ;;
esac

OPENMRS_HOME=/usr/local/tomcat/.OpenMRS

# Move OWA and modules to OpenMRS home

mkdir -p $OPENMRS_HOME/owa
mkdir -p $OPENMRS_HOME/modules
mkdir -p $OPENMRS_HOME/frontend

# Clean the directories from old modules/versions
rm -rf $OPENMRS_HOME/modules/*
rm -rf $OPENMRS_HOME/owa/*
rm -rf $OPENMRS_HOME/frontend/*

echo 'Copying OpenMRS modules'
cp -r /opt/openmrs-modules/* $OPENMRS_HOME/modules/

echo 'Copying OpenMRS OWA apps'
cp -r /opt/openmrs-owa/* $OPENMRS_HOME/owa/

echo 'Copying OpenMRS 3.x frontend'
cp -r /opt/openmrs-frontend/* $OPENMRS_HOME/frontend/

COPY_CFL_MODULES=${COPY_CFL_MODULES:-"true"}

if [ "$COPY_CFL_MODULES" != "false" ]; then
    echo 'Copying CFL modules'
    cp -r /opt/cfl-modules/* $OPENMRS_HOME/modules/
fi


#echo 'Check for OCL Import'
RUN_OCL_IMPORT=${RUN_OCL_IMPORT:-"false"}
if [ "$RUN_OCL_IMPORT" == "true" ]; then
    echo 'Copy OCL import ZIP - will be imported during startup'
    mkdir -p $OPENMRS_HOME/ocl/configuration/loadAtStartup
    cp -r /opt/openmrs-ocl/* $OPENMRS_HOME/ocl/configuration/loadAtStartup/
else
    echo 'Clear OCL import ZIP - will NOT be imported during startup'
    rm -rf $OPENMRS_HOME/ocl/configuration/loadAtStartup
fi

mkdir -p ~/modules

# Create OpenMRS installation script - see setenv.sh
cat > /usr/local/tomcat/openmrs-server.properties << EOF
install_method=auto
connection.url=jdbc\:mysql\://${DB_HOST}\:3306/${DB_DATABASE}?autoReconnect\=true&sessionVariables\=default_storage_engine\=InnoDB&useUnicode\=true&characterEncoding\=UTF-8&sslMode\=${DB_SSL_MODE}&allowPublicKeyRetrieval\=true
connection.username=${DB_USERNAME}
connection.password=${DB_PASSWORD}
has_current_openmrs_database=true
create_database_user=false
module_web_admin=${MODULE_WEB_ADMIN}
create_tables=${DB_CREATE_TABLES}
auto_update_database=${DB_AUTO_UPDATE}
EOF

# Create default person image folder
mkdir -p /usr/local/tomcat/.OpenMRS/person_images

echo "------  Starting CFL distribution -----"
cat /root/openmrs-distro.properties
echo "-----------------------------------"

# wait for mysql to initialise
/usr/local/tomcat/wait-for-it.sh --timeout=3600 ${DB_HOST}:3306

# Existing installs read the persisted runtime properties, not the installation script above: set the JDBC TLS mode
# there before Tomcat starts. Any useSSL/sslMode parameter is dropped and exactly one sslMode is added.
RUNTIME_PROPERTIES=$OPENMRS_HOME/openmrs-runtime.properties
if [ -f "$RUNTIME_PROPERTIES" ]; then
  echo "Setting sslMode=${DB_SSL_MODE} in openmrs-runtime.properties"
  sed -i -E '/^connection\.url=/ {
    s/&(useSSL|sslMode)\\?=[A-Za-z_]+//g
    s/\?(useSSL|sslMode)\\?=[A-Za-z_]+&?/?/
    s/\?$//
  }' "$RUNTIME_PROPERTIES"
  if grep -q '^connection\.url=.*?' "$RUNTIME_PROPERTIES"; then
    sed -i -E '/^connection\.url=/ s/$/\&sslMode\\='"${DB_SSL_MODE}"'/' "$RUNTIME_PROPERTIES"
  else
    sed -i -E '/^connection\.url=/ s/$/?sslMode\\='"${DB_SSL_MODE}"'/' "$RUNTIME_PROPERTIES"
  fi
fi

# start tomcat in background; the JDWP agent only when DEBUG=true (docker-compose.debug.yml)
if [ "$DEBUG" = true ]; then
    export JPDA_ADDRESS="1044"
    export JPDA_TRANSPORT=dt_socket
    /usr/local/tomcat/bin/catalina.sh jpda run &
else
    /usr/local/tomcat/bin/catalina.sh run &
fi

# trigger first filter to start data importation
sleep 15
echo "Triggerring data import"
curl -L http://localhost:8080/openmrs/ > /dev/null
echo "Data import triggered"
sleep 15

# Add properties ONLY if file exists
if [ -f "/usr/local/tomcat/.OpenMRS/openmrs-runtime.properties" ]; then
  echo "Decorating openmrs-runtime.properties"

  # add development mode properties
  grep -qxF 'uiFramework.developmentFolder=/usr/local/modules' /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo 'uiFramework.developmentFolder=/usr/local/modules' >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
  grep -q 'uiFramework.developmentModules' /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "uiFramework.developmentModules=${DEV_MODE_MODULES}" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
  sed -i "s/uiFramework.developmentModules=.*/uiFramework.developmentModules=${DEV_MODE_MODULES}/g" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties

  # disabling cache properties
  grep -qxF "net.sf.ehcache.disabled=true" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "net.sf.ehcache.disabled=true" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
  grep -qxF "hibernate.cache.use_second_level_cache=false" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "hibernate.cache.use_second_level_cache=false" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
  grep -qxF "hibernate.cache.use_query_cache=false" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "hibernate.cache.use_query_cache=false" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
  grep -qxF "hibernate.cache.auto_evict_collection_cache=false" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "hibernate.cache.auto_evict_collection_cache=false" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties

  # Temporary disable csrfguard
  grep -qxF "org.owasp.csrfguard.Enabled=false" /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties || echo "org.owasp.csrfguard.Enabled=false" >> /usr/local/tomcat/.OpenMRS/openmrs-runtime.properties
fi

# bring tomcat process to foreground again
wait ${!}
