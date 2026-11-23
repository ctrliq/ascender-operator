FROM quay.io/operator-framework/ansible-operator:main

USER root
# certifi/virtualenv: GHSA-6q48-6c7w-9gw2, drop once ansible-operator-plugins#252 lands
RUN microdnf update -y && \
    microdnf install -y openssl && \
    set -- /usr/share/python3.12-wheels/pip-*.whl && \
    python3.12 "$1/pip" install --no-cache-dir --upgrade 'certifi>=2026.10.23' && \
    python3.12 "$1/pip" uninstall -y virtualenv

USER 1001

ARG DEFAULT_AWX_VERSION
ARG OPERATOR_VERSION
ENV DEFAULT_AWX_VERSION=${DEFAULT_AWX_VERSION}
ENV OPERATOR_VERSION=${OPERATOR_VERSION}

COPY requirements.yml ${HOME}/requirements.yml
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && chmod -R ug+rwx ${HOME}/.ansible

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
COPY playbooks/ ${HOME}/playbooks/

ENTRYPOINT ["/tini", "--", "/usr/local/bin/ansible-operator", "run", \
    "--watches-file=./watches.yaml", \
    "--reconcile-period=0s" \
    ]
