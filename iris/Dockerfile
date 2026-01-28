ARG IMAGE=containers.intersystems.com/intersystems/iris-community:latest-em
FROM $IMAGE

USER root

WORKDIR /opt/irisapp
RUN chown -R irisowner:irisowner /opt/irisapp

USER irisowner

COPY --chown=irisowner:irisowner /iris/src src

COPY --chown=$ISC_PACKAGE_MGRUSER:$ISC_PACKAGE_IRISGROUP /iris/iris.cpf /
RUN chmod +x /iris.cpf

ENV ISC_CPF_MERGE_FILE=/iris.cpf

# copy files to image
WORKDIR /opt/irisapp
COPY --chown=irisowner:irisowner iris/iris.script iris.script

# run iris.script
RUN iris start IRIS \
    && iris session IRIS < /opt/irisapp/iris.script \
    && iris stop IRIS quietly