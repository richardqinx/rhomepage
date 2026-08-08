HUGO ?= hugo
PORT ?= 1314

.PHONY: build serve clean

build: clean
	$(HUGO)
	./scripts/publish-raw

serve: build
	$(HUGO) server --disableFastRender --disableLiveReload --port $(PORT)

clean:
	$(RM) -r public resources .hugo_build.lock
