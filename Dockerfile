# syntax=docker/dockerfile:1
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ARG USER=dev
ARG UID=1000
ARG GID=1000

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    curl wget ca-certificates unzip xz-utils git \
    python3 python3-pip \
    openjdk-17-jdk-headless \
    picocom udev sudo \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

RUN pip3 install --no-cache-dir -q platformio

ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"
RUN wget -q https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.16.0-stable.tar.xz \
    && tar xf flutter_linux_3.16.0-stable.tar.xz -C /opt/ \
    && rm flutter_linux_3.16.0-stable.tar.xz

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"
RUN mkdir -p /opt/android-sdk/cmdline-tools /tmp/sdk \
    && cd /tmp/sdk \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-10406996_latest.zip \
    && unzip -q commandlinetools-linux-10406996_latest.zip \
    && mv cmdline-tools /opt/android-sdk/cmdline-tools/latest \
    && rm -rf /tmp/sdk

RUN printf 'SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666"\nSUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"\nSUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666"\n' > /etc/udev/rules.d/99-esp32.rules
RUN printf 'SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", MODE="0666"\nSUBSYSTEM=="usb", ATTRS{idVendor}=="04e8", MODE="0666"\nSUBSYSTEM=="usb", ATTRS{idVendor}=="2717", MODE="0666"\n' > /etc/udev/rules.d/99-android.rules

RUN groupadd -f -g ${GID} ${USER} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USER} \
    && usermod -aG sudo,dialout ${USER} \
    && echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && chown -R ${USER}:${USER} /opt/android-sdk /opt/flutter

USER ${USER}
RUN mkdir -p /home/${USER}/.platformio

RUN yes | sdkmanager --sdk_root=${ANDROID_HOME} --licenses 2>/dev/null
RUN sdkmanager --sdk_root=${ANDROID_HOME} "platforms;android-34" "build-tools;34.0.0" "platform-tools" 2>&1 | tail -1

RUN flutter config --android-sdk ${ANDROID_HOME} 2>/dev/null
RUN flutter doctor --android-licenses 2>/dev/null
RUN flutter precache --web --android 2>/dev/null

RUN pio pkg install --global -p "espressif32" 2>&1 | tail -2 || pio pkg install --global -p "espressif32" --skip-dependencies 2>&1 | tail -2 || true

USER root
COPY <<'ENTRYPOINT' /entrypoint.sh
#!/bin/bash
set -e
if [ -d /workspace ]; then
  WUID=$(stat -c "%u" /workspace 2>/dev/null || echo "0")
  WGID=$(stat -c "%g" /workspace 2>/dev/null || echo "0")
  if [ "$WUID" != "0" ] && [ "$WUID" != "$(id -u dev)" ]; then
    usermod -u "$WUID" dev 2>/dev/null
    groupmod -g "$WGID" dev 2>/dev/null || true
    chown -R dev:dev /home/dev 2>/dev/null
    chown -R dev:dev /opt/flutter /opt/android-sdk 2>/dev/null || true
  fi
fi
[ -d /sys/class/ ] && udevadm control --reload-rules 2>/dev/null || true
adb start-server 2>/dev/null || true
exec su - dev -c "$*"
ENTRYPOINT
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]