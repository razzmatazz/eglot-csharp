LOCAL_IMAGE := eglot-csharp-test
SRC         := /src

DOCKER := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
ifeq ($(DOCKER),)
  $(error Neither docker nor podman found on PATH)
endif

DOCKER_RUN = $(DOCKER) run --rm \
               -v "$(CURDIR)":$(SRC) \
               -w $(SRC) \
               $(LOCAL_IMAGE)

.PHONY: image compile lint test ci clean

image:
	$(DOCKER) build -t $(LOCAL_IMAGE) .

clean:
	find . -maxdepth 1 -name '*.elc' -delete

compile: image clean
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask compile --strict"

lint: image
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask lint checkdoc && eask lint package"

test: image
	$(DOCKER_RUN) sh -c "eask install-deps --dev && eask test ert test/eglot-csharp-tests.el"

# compile, lint and test each spin up their own container and are independent
# of each other once the image exists — run them in parallel with -j3.
ci: image
	$(MAKE) compile lint test
