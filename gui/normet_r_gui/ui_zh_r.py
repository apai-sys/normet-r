"""The R GUI's own texts in Chinese, beside the catalogue it shares with normet-py's window.

``ui_zh`` is normet-py's catalogue, kept as it is there so the two stay in step; this
module holds what only this window says (R, Rscript, H2O, the steps' tooltips as written
here). It is merged over ``ui_zh.TEXTS`` (see ``uilang._catalogue``). Templates use the
same marks: ``{n0}`` for a number, ``{s0}`` for a name or other free text. A text is
matched with its whitespace collapsed, so a tooltip written over several lines is one
entry. Data's own words -- column names, backends, methods -- are not translated.
"""

TEXTS: dict[str, str] = {
    # -- menus ------------------------------------------------------------------------------
    "&R": "&R",
    "&Locate Rscript…": "定位 Rscript(&L)…",
    "Locate Rscript": "定位 Rscript",
    "&Check R environment": "检查 R 环境(&C)",
    "Check R environment": "检查 R 环境",
    "Edit": "编辑",
    "Help": "帮助",
    "Quit": "退出",
    "Analysis": "分析",
    "Language": "语言",
    "Open Recent": "最近打开",
    "Load Example Data": "载入示例数据",
    # -- the R environment -------------------------------------------------------------------
    "R: checking…": "R：检查中…",
    "R: normet package missing": "R：缺少 normet 包",
    "R: not found": "R：未找到",
    "normet R package not available": "normet R 包不可用",
    "R was found but the normet package could not be loaded.": "已找到 R，但无法加载 normet 包。",
    "Install it in R with:": "请在 R 中运行以下命令安装：",
    "Normet — weather normalisation & counterfactual toolkit": "Normet——气象归一化与反事实分析工具",
    # -- tabs --------------------------------------------------------------------------------
    "① Data": "① 数据",
    "② Model": "② 模型",
    "③ Normalise": "③ 归一化",
    "④ Decompose": "④ 分解",
    "⑤ Rolling": "⑤ 滚动",
    "⑥ PDP": "⑥ PDP",
    "① Features": "① 特征",
    "① Panel": "① 面板",
    "① Stations": "① 站点",
    "② Preview": "② 预览",
    "③ Table": "③ 表格",
    "Step 1": "第 1 步",
    "Step 2": "第 2 步",
    "Step 3": "第 3 步",
    "Step 4": "第 4 步",
    "Step 5": "第 5 步",
    # -- placeholders of the result tabs -----------------------------------------------------
    "Train a model (Step 1) to see its quality here.": "训练模型（第 1 步）后在此查看其质量。",
    "Run Step 2 to see observed vs. meteorologically normalised series.": (
        "运行第 2 步以查看观测序列与气象归一化序列的对比。"
    ),
    "Run Step 3 to see the decomposition — emission splits the normalised series into "
    "time scales; meteorology splits observed − normalised by met variable.": (
        "运行第 3 步以查看分解结果——emission 将归一化序列拆分到各时间尺度；"
        "meteorology 将观测 − 归一化按气象变量拆分。"
    ),
    "Run Step 4 to see the rolling normalisation.": "运行第 4 步以查看滚动归一化。",
    "Run Step 5 to see partial-dependence curves.": "运行第 5 步以查看部分依赖曲线。",
    "Run Step 2 (Normalise) then Multi-scale decomposition to see how meteorological "
    "residuals split across fast/meso/slow timescales.": (
        "先运行第 2 步（归一化），再运行多尺度分解，即可查看气象残差在快/中/慢时间尺度上的分配。"
    ),
    "Run Step 2 (Normalise) first — it provides Y_∞, the full-record baseline.": (
        "请先运行第 2 步（归一化）——它提供全记录基线 Y_∞。"
    ),
    # -- Step 1: train -----------------------------------------------------------------------
    "Prepare the data and train the machine-learning model in R. Everything below needs "
    "a trained model.": "在 R 中准备数据并训练机器学习模型。下方所有步骤都需要已训练的模型。",
    "lightgbm = LightGBM with random hyperparameter search (fast, default). h2o = H2O "
    "AutoML (needs Java + the h2o R package).": (
        "lightgbm = 带随机超参数搜索的 LightGBM（快速，默认）。"
        "h2o = H2O AutoML（需要 Java 和 h2o R 包）。"
    ),
    "Algorithms": "算法",
    "H2O AutoML algorithms to search over (include_algos), within the time budget. GBM "
    "is the fastest and usually sufficient; tick more to widen the search.": (
        "H2O AutoML 在时间预算内搜索的算法（include_algos）。GBM 最快，通常已足够；"
        "勾选更多可扩大搜索范围。"
    ),
    "H2O AutoML max_runtime_secs.": "H2O AutoML 的 max_runtime_secs。",
    "Gradient boosting machine (default, fast)": "梯度提升机（默认，快速）",
    "Distributed random forest (+ extremely randomised trees)": "分布式随机森林（+ 极端随机树）",
    "Generalised linear model (elastic net)": "广义线性模型（弹性网络）",
    "Feed-forward neural network": "前馈神经网络",
    "XGBoost (not available on Apple-Silicon H2O builds)": "XGBoost（Apple Silicon 版 H2O 不可用）",
    "Ensemble of the other models (needs ≥ 2 base models)": "其他模型的集成（需要 ≥ 2 个基模型）",
    "Filled with the trained features after Step 1.": "第 1 步训练后填入已训练的特征。",
    "Data loaded — check the target and features, then ▶ Train model (Step 1).": (
        "数据已载入——请检查目标变量和特征，然后点击 ▶ 训练模型（第 1 步）。"
    ),
    "Model trained — check its quality, then run Step 2 (normalisation).": (
        "模型已训练——请检查其质量，然后运行第 2 步（归一化）。"
    ),
    "Train a model first (Step 1).": "请先训练模型（第 1 步）。",
    # -- Step 2-5 ----------------------------------------------------------------------------
    "Tick at least one variable to resample in Step 2 (usually the meteorological ones).": (
        "请在第 2 步中至少勾选一个要重采样的变量（通常是气象变量）。"
    ),
    "Normalisation done — the meteorologically normalised series is on tab ③.": (
        "归一化完成——气象归一化后的序列在第 ③ 个标签页。"
    ),
    "emission: split the normalised series (Step 2) into time scales (trend / seasonal / "
    "weekly / diurnal / noise). meteorology: split observed − normalised into the "
    "contribution of each individual meteorological variable.": (
        "emission：将归一化序列（第 2 步）拆分到各时间尺度（趋势 / 季节 / 周 / 日 / 噪声）。"
        "meteorology：将观测 − 归一化拆分为每个气象变量各自的贡献。"
    ),
    "Windowed re-normalisation — reveals slow changes in the emission signal. Resamples "
    "the variables ticked in Step 2.": (
        "分窗重新归一化——揭示排放信号的缓慢变化。重采样第 2 步中勾选的变量。"
    ),
    "Differences Y_fast − Y_meso − Y_slow − Y_∞ (Step 2) isolate the meteorological "
    "residual specific to each timescale — like wavelet detail coefficients or MSTL's "
    "trend/seasonal/remainder.": (
        "差分 Y_fast − Y_meso − Y_slow − Y_∞（第 2 步）分离出每个时间尺度特有的气象残差"
        "——类似小波细节系数或 MSTL 的趋势/季节/余项。"
    ),
    "Runs rolling normalisation at three window widths and differences them against each "
    "other and against Step 2's Y_∞ — needs Step 2 (Normalise) to have been run first, and "
    "is roughly 3× the cost of a single Rolling run.": (
        "以三种窗口宽度运行滚动归一化，并将它们相互比较、与第 2 步的 Y_∞ 比较求差——"
        "需要先运行第 2 步（归一化），耗时约为单次滚动运行的 3 倍。"
    ),
    "Multi-scale decomposition needs Y_∞ from Step 2 (Normalise) as its full-record "
    "baseline — run Normalise, then come back here.": (
        "多尺度分解需要第 2 步（归一化）得到的 Y_∞ 作为全记录基线——请先运行归一化，再回到这里。"
    ),
    "Run Step 2 first": "请先运行第 2 步",
    "Split the observed series into additive contributions (leave-one-out normalisation).": (
        "将观测序列拆分为可加的贡献（留一法归一化）。"
    ),
    "Tick at least one variable in Step 5.": "请在第 5 步中至少勾选一个变量。",
    "Single-file HTML report of the current tab's result.": "当前标签页结果的单文件 HTML 报告。",
    "normet — {s0} report": "normet——{s0} 报告",
    "Generated {s0}": "生成于 {s0}",
    "Result (first 50 rows)": "结果（前 50 行）",
    "Configuration": "配置",
    # -- SCM Studio --------------------------------------------------------------------------
    "Augmented SCM (ridge) — the recommended default.": "增强合成控制（岭回归）——推荐的默认方法。",
    "Classic Abadie SCM (simplex weights).": "经典 Abadie 合成控制（单纯形权重）。",
    "Difference-in-differences baseline.": "双重差分基准。",
    "ML-augmented SCM (LightGBM/H2O) — experimental, slower.": (
        "机器学习增强合成控制（LightGBM/H2O）——实验性，较慢。"
    ),
    "Matrix-completion (MC-NNM) estimator.": "矩阵补全（MC-NNM）估计器。",
    "Robust SCM (de-noised donor matrix).": "稳健合成控制（去噪的供体矩阵）。",
    "Hyperparameter-search trials per fit (LightGBM). Placebo tests refit many times — "
    "keep this small.": "每次拟合的超参数搜索次数（LightGBM）。安慰剂检验会多次重新拟合——请设小一些。",
    # -- Data Studio -------------------------------------------------------------------------
    "Fetch UK air quality (AURN, AQE, SAQN, WAQN, NI, LMAM) and optionally ERA5 meteorology "
    "via the Copernicus CDS, through the normet R package, merged into a model-ready table.": (
        "通过 normet R 包获取英国空气质量数据（AURN、AQE、SAQN、WAQN、NI、LMAM），"
        "并可选通过 Copernicus CDS 获取 ERA5 气象数据，合并为可直接建模的表格。"
    ),
    "Download the pollutant series (and the meteorology) in R, and join them into one "
    "hourly table ready for Step 1 training.": (
        "在 R 中下载污染物序列（及气象数据），并合并为一张逐小时表格，可直接用于第 1 步训练。"
    ),
    "Adds t2m, d2m, sp, tcc, tp, ssrd, u10, v10, blh — the predictors the Train step "
    "auto-recognises as met.": (
        "添加 t2m、d2m、sp、tcc、tp、ssrd、u10、v10、blh——训练步骤会自动识别为气象变量的预测变量。"
    ),
    "Load the merged table into the main window, ready for Step 1.": (
        "将合并后的表格载入主窗口，以便进行第 1 步。"
    ),
    "Columns follow the modelling convention: met variables are auto-ticked as features in "
    "Step 1.": "列名遵循建模约定：气象变量会在第 1 步中自动勾选为特征。",
    "Sent to the main window — continue with Step 1 there.": "已发送到主窗口——请在主窗口继续第 1 步。",
    "Running in R: {s0}…": "正在 R 中运行：{s0}…",
    "No pollutants at this site": "该站点没有污染物数据",
    "The selected site measures none of the ticks.": "所选站点没有测量任何已勾选的项目。",
    "e.g. Manchester": "例如 Manchester",
    # -- Transport Studio --------------------------------------------------------------------
    "No GDAS1 files downloaded yet.": "尚未下载 GDAS1 文件。",
    "Download GDAS1 files first (or point to existing ARL met files).": (
        "请先下载 GDAS1 文件（或指定已有的 ARL 气象文件）。"
    ),
    "{n0} GDAS1 file(s) ready: {s0}": "{n0} 个 GDAS1 文件已就绪：{s0}",
    "Exact point-in-polygon residence time instead of a bounding box — use real "
    "administrative or airshed boundaries. Pick several at once, or click again to add "
    "more; rename a row by double-clicking its 'name' cell.": (
        "用精确的点在多边形内判断计算停留时间，代替边界框——可使用真实的行政区或空气域边界。"
        "可一次选择多个，或再次点击继续添加；双击某行的 'name' 单元格可重命名。"
    ),
    "If these tdump files are all for one receptor site, name it here — the result gets a "
    "'site' column, so batches from several sites (processed one at a time) can all be sent "
    "to the main window and matched up correctly.": (
        "如果这些 tdump 文件都属于同一个受体点，请在此命名——结果会带有 'site' 列，"
        "这样多个站点的批次（逐一处理）都能发送到主窗口并正确匹配。"
    ),
    "One or more (name, lat, lon) rows. With more than one, the combined result is tagged "
    "with a 'site' column.": "一行或多行（name, lat, lon）。多于一行时，合并结果会带有 'site' 列。",
    "One row per receptor site. hyts_std runs once per (site, time), so results are tagged "
    "with a 'site' column when there is more than one row.": (
        "每个受体点一行。hyts_std 对每个（站点, 时间）运行一次，因此多于一行时结果会带有 'site' 列。"
    ),
    "Join the traj_* columns onto the main window's data: each row takes the latest "
    "trajectory to have arrived, within one release interval, ready to tick as predictors "
    "in Step 1.": (
        "将 traj_* 列连接到主窗口的数据上：每一行取一个释放间隔内最近已到达的轨迹，"
        "之后可在第 1 步中勾选为预测变量。"
    ),
    "The main window's date range is empty.": "主窗口的日期范围为空。",
    "Sent to the main window — features joined onto its data.": "已发送到主窗口——特征已连接到其数据上。",
    "{n0} transport features × {n1} rows ({n2} sites).": (
        "{n2} 个站点共 {n0} 个传输特征 × {n1} 行。"
    ),
    "Built {n0} transport features for {n1} receptor times across {n2} site(s).": (
        "为 {n2} 个站点的 {n1} 个受体时刻构建了 {n0} 个传输特征。"
    ),
    "Cannot join": "无法连接",
    "Nothing joined": "没有连接任何数据",
    "No row of the data took a trajectory: check that the sites and dates match the "
    "trajectories'. The data was left as it was.": (
        "数据中没有任何一行取到轨迹：请检查站点和日期是否与轨迹一致。数据保持不变。"
    ),
    # -- the R package's backends (Step 1, SCM Studio) ----------------------------------------
    "lightgbm = LightGBM with random hyperparameter search (fast, default).": (
        "lightgbm = 使用随机超参数搜索的 LightGBM（快速，默认）。"
    ),
    "h2o = H2O AutoML search (uses the time budget below; needs Java and the h2o R package).": (
        "h2o = H2O AutoML 搜索（使用下方的时间预算；需要 Java 和 h2o R 包）。"
    ),
    "h2o = H2O AutoML (uses the time budget; needs Java and the h2o R package).": (
        "h2o = H2O AutoML（使用时间预算；需要 Java 和 h2o R 包）。"
    ),
    "AutoML search time (H2O backend: max_runtime_secs).": "AutoML 搜索时间（H2O 后端：max_runtime_secs）。",
    "Algorithms": "算法",
    "H2O AutoML time per fit (max_runtime_secs). Placebo tests refit many times — keep this small.": (
        "每次拟合的 H2O AutoML 时间（max_runtime_secs）。安慰剂检验会多次重新拟合——请设小一些。"
    ),
    "LightGBM random-search trials per fit. Placebo tests refit many times — keep this small.": (
        "每次拟合的 LightGBM 随机搜索次数。安慰剂检验会多次重新拟合——请设小一些。"
    ),
    "Bayesian simplex SCM (MCMC) — gives credible bands.": "贝叶斯单纯形 SCM（MCMC）——给出可信区间带。",
    "Chronos-2 is normet-py's foundation model (PyTorch); the R package has none.": (
        "Chronos-2 是 normet-py 的基础模型（PyTorch），R 包中没有。"
    ),
    "Use normet-py's window for it.": "请使用 normet-py 的窗口。",
}
