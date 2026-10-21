# syntax=docker/dockerfile:1
# 更新 APK 或启动脚本时，只构建这个镜像。
ARG BASE_IMAGE=registry.example.com/testing/android-emulator-base:api35-v1
FROM ${BASE_IMAGE}

ENV HOME=/data/home \
    ANDROID_USER_HOME=/data/home/.android \
    ANDROID_AVD_HOME=/data/avd \
    AVD_NAME=BoltzLog_API_35 \
    EMULATOR_MEMORY_MB=2048 \
    EMULATOR_CORES=4 \
    BOOT_TIMEOUT_SECONDS=600 \
    APP_PACKAGE=com.entropix.boltzlog \
    APP_ACTIVITY=.MainActivity

COPY app/app.apk /opt/app/app.apk
COPY start-emulator.sh healthcheck.sh /usr/local/bin/
RUN sed -i 's/\r$//' /usr/local/bin/start-emulator.sh /usr/local/bin/healthcheck.sh \
    && chmod 755 /usr/local/bin/start-emulator.sh /usr/local/bin/healthcheck.sh \
    && test -s /opt/app/app.apk

EXPOSE 5037
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=15s --start-period=900s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh", "ready"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/start-emulator.sh"]
