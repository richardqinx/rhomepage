---
title: "{{ replace .File.ContentBaseName "-" " " | title }}"
slug: "{{ .File.ContentBaseName }}"
lang: en
created: {{ .Date.Format "2006-01-02" }}
updated: {{ .Date.Format "2006-01-02" }}
license: CC-BY-SA-4.0
---
