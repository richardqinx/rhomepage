HUGO ?= hugo
PORT ?= 1314
BASE_URL ?= http://localhost:1314/

.PHONY: build serve clean

build: clean
	$(HUGO) --baseURL "$(BASE_URL)"
	./scripts/publish-raw

serve: build
	$(HUGO) server --disableFastRender --disableLiveReload --port $(PORT) --baseURL "http://localhost:$(PORT)/"

clean:
	$(RM) -r public resources .hugo_build.lock
