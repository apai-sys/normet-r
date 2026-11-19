---
name: Bug report
about: Something in normet does not work as documented
title: ""
labels: bug
assignees: ""
---

**What happened**

A clear description of the bug, and what you expected to happen instead.

**Minimal reproducible example**

Please give the smallest code that shows the problem. Use a bundled dataset
(`my1`, `my1_pm25`, `traj_my1`, `scm`) or a few rows of simulated data if you can.
The [reprex](https://reprex.tidyverse.org) package makes this easy.

```r
library(normet)

```

**Environment**

- normet version (`packageVersion("normet")`):
- Backend (`lightgbm` / `h2o`) and its version:
- Operating system:
- Output of `sessionInfo()`:

<details>
<summary>sessionInfo()</summary>

```
paste here
```

</details>

**Desktop GUI only**

If the problem is in the desktop app (`gui/`), say how you installed it
(`pip install ./gui` or an installer) and attach its command log if you can.
