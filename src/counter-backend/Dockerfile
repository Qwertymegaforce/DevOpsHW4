FROM python:3.11-slim-bookworm AS base


FROM base AS build
SHELL [ "/bin/sh", "-eu", "-c" ]
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
RUN pip install --no-cache-dir 'poetry==1.8.*'

WORKDIR /build
COPY pyproject.toml poetry.lock README.md ./
COPY src/ src/
RUN \
  mkdir -p dist \
  && poetry export --without-hashes --format constraints.txt --output dist/constraints.txt \
  && pip wheel --no-cache-dir --isolated --requirement dist/constraints.txt --wheel-dir dist/vendor \
  && poetry build --format wheel


FROM base AS final

COPY --from=build /build/dist/ /tmp/dist/
RUN pip install --no-cache-dir --no-index --find-links /tmp/dist/vendor /tmp/dist/*.whl \
 && rm -rf /tmp/dist

ENV HOST="0.0.0.0"
ENV PORT="8080"
USER nobody
EXPOSE ${PORT}/tcp
ENTRYPOINT [ "server" ]
