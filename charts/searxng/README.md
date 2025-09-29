# SearXNG

This is my helm chart for [SearXNG](https://docs.searxng.org/), a free internet
metasearch engine.

## Source Code

* <https://github.com/darkhonor/helm-charts>
* <https://github.com/searxng/searxng>

## Installing

Before you can install, you need to add the `darkhonor` repo to [Helm](https://helm.sh)

```shell
helm repo add darkhonor https://darkhonor.github.io/helm-charts
helm repo update
```

Now you can install the chart:

```shell
helm upgrade --install searxng darkhonor/searxng
```

## Values

Here are the values which can be modified in the installation:

## Author

Alex Ackerman, @darkhonor
