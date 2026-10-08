---
title: "{{ replace .File.ContentBaseName "-" " " | title }}"
slug: "{{ .File.ContentBaseName }}"
lang: en
created: {{ time.Format "2006-01-02" .Date }}
updated: {{ time.Format "2006-01-02" .Date }}
license: CC-BY-SA-4.0
---
