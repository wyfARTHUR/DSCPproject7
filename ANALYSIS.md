# 分析方法与代码说明

研究问题：对同一本书，电子书和数字有声书的借阅份额是否比纸质版衰减得更慢？
学校环境为 CHTC/HTCondor。**实际提交步骤请先阅读 [CHTC.md](CHTC.md)**，不需要在 learn 上安装 R。
本文件说明与调度系统无关的 R 分析代码、匹配规则和本地测试。

## R 处理阶段

| 脚本 | 工作 |
| --- | --- |
| `scripts/01_prepare_year.R` | 年度月度 CSV 校验、格式筛选、分母和作品计数聚合、年度 Parquet |
| `scripts/02_build_shards.R` | 跨年匹配、人工别名、审核样本和完整时间序列分片 |
| `scripts/03_fit_shard.R` | 一个作品分片的主分析与疫情敏感性拟合 |
| `scripts/04_compare_plot.R` | 固定效应比较、拟合状态汇总、统计表与 PNG/PDF 图表 |

需要 R 4.1+ 和 `data.table`、`arrow`、`stringi`、`digest`、`jsonlite`、`ggplot2`。
本地已有 R 时可以运行 `Rscript scripts/install_packages.R`，缺少的包安装到 `.Rlib/`。
CHTC 使用仓库提供的 Apptainer 配方安装这些包，而不是假设执行节点预装 R。

各脚本均从仓库根目录运行，接受 `--config config/analysis.json --out 输出目录`。
年度脚本还需 `--year 2023`，拟合脚本需 `--shard 1`。
手工运行完整数据处理时，应在已分配的计算资源上进行。

## 数据与人工匹配

格式映射在 `config/format_map.tsv`：`BOOK/REGPRINT/LARGEPRINT + Physical` 归为纸质书；
`EBOOK + Digital` 和 `AUDIOBOOK + Digital` 分别为电子书和数字有声书。其他类型不会混入这三个格式。
质量表会列出所有原始材料类型/使用类别及其记录数。

自动规则包括 Unicode 规范化、大小写/标点/空白处理，去掉明确的格式标记和书名后的责任说明，
以及作者 `姓, 名, 生卒年` 的规范化。保留副标题和 abridged 信息，不使用模糊匹配，也不根据缺失作者猜测身份。
同名同作者仍可能存在版本、语言或汇编差异，因此需要人工抽查。

`audit/match_review.tsv` 默认抽取最多 200 个自动匹配作品，另加所有人工别名作品。
组员填写 `decision=accept/reject`、`reviewer` 和 `notes`。这是抽样审核，不代表每本书均已人工核验。
`audit/match_candidates.tsv` 提供对应的规范化键及原始示例。

`config/match_overrides.tsv` 的每行指定精确 `title_norm`、`creator_norm`、目标 `work_id`、
`include=TRUE/FALSE` 和依据 `notes`。不同键使用相同 `work_id` 才会人工合并；`work_id` 留空表示沿用自动 ID。
修正后重建合并阶段，再检查审核表，最后重新拟合。`reject` 排除整本作品，但不改变格式月度分母。
不要删除审核行或修改审核签名。

在有 R 的本地或交互计算环境，可以查找其他标题：

```bash
Rscript scripts/find_work.R --out analysis_output/run1 --query "harry potter"
```

CHTC 的中间结果保存在传回的归档中；先解包成相应目录结构，再在有 R 的环境使用该查询脚本。
审核不完整时普通拟合会停止。只有显式指定 `--allow-unreviewed true` 才允许探索拟合，
且结果、图注和摘要均标记 `PRELIMINARY_UNREVIEWED`；不会自动填写人工审核。

## 统计定义与可调整选择

设置位于 `config/analysis.json`，所有月份使用真实日历月份：

1. 读取 2010 年 1 月到 2025 年 2 月，排除 2024 年 5、6 月。
2. 每个作品格式月的份额为该作品借阅量除以**该格式全体书籍**当月借阅量。
   分母在剔除缺失书名/作者、匹配、审核和多格式筛选之前计算。
3. 合并每个作品的完整跨年序列后，对每个格式取最高份额的月份作为峰值；并列时取最早月份。
4. 从峰值开始拟合 `share(t) = A * exp(beta * t)`，`A ≥ 0`，时间单位为日历月。
   使用原始份额上的等权非线性最小二乘，解析消去振幅，再用网格定位及一维优化寻找速率。
   **不对份额取对数**，因此明确记录的零借阅月份仍可进入拟合。
5. 至少需要 12 个严格晚于峰值的有效观测月份；峰值本身不计入这 12 个。
   分母为零的月份排除；源数据没有出现的作品月份保持缺失，不补零，不压缩日历间隔。
6. `beta < -1e-6` 且不在搜索边界时，半衰期为 `log(2)/(-beta)`。
   非衰减、观测不足、无正份额以及速率落在边界的拟合分别报告。
   默认速率边界为每月 `[-1, 1]`；靠近零的极长半衰期保留，不擅自截断。
7. 主比较采用 `log(half_life) ~ format + book fixed effects`。
   每个比较作品须有可估计的衰减纸质版和至少一种衰减数字版。
   通过组内去均值实现固定效应，按作品聚类的 CR1 协方差和 `G-1` 自由度 t 分布计算区间。
   输出的 `exp(coefficient)` 是相对于纸质版的半衰期比值。
8. 疫情敏感性版本删去配置的 2020 年 3 月至 2021 年 12 月，并重新寻找峰值和拟合。
   这是可修改的分析窗口，不是关于实际闭馆日期的断言；被删月份不会被重新编号。

这是描述性比较。库存、平台授权、可借阅状态、截尾、匹配错误和可估计样本选择仍有限制。
峰值在观测窗口起点的情况会单独标记。比较区间没有传播每条衰减曲线的参数估计不确定性。
后续可按老师反馈修改这些分析选择，不应把当前方法默认为唯一方案。

## 最终输出与资源记录

`OUT/results/` 包括：

- `all_fits.parquet`：每个作品/格式/情景的完整拟合结果。
- `format_comparison.tsv`：固定效应比较、半衰期比值、区间、样本量和审核状态。
- `fit_status_counts.tsv`、`non_decaying.tsv`、`unestimable.tsv`：拟合状态和未进入比较的原因。
- `run_summary.json`：日期范围、审核状态、方法和限制。
- `figures/*.png` 和 `figures/*.pdf`：月度总借阅量、半衰期比较、拟合状态、示例衰减曲线。
  示例按可比较作品总借阅量排序选择，不按效果大小挑选。

`OUT/metrics/` 保存每个任务的运行秒数、R 堆内存峰值、HTCondor ID 和 R/package session 信息。
R 堆内存不等于进程 RSS；实际 CHTC 资源用量需要查看 HTCondor `.log` 或历史记录。
缺少分片、配置/代码/别名不一致或审核变化时，后续阶段会报错，避免静默合并陈旧或不完整的结果。
更改分析设置或代码后，使用新的运行目录；改变审核决定后重新拟合所有分片。

## 本地小规模验证

这些命令生成的是模拟数据测试，不是研究结论：

```bash
Rscript tests/test_models.R
Rscript tests/test_pipeline.R
Rscript tests/test_chtc.R
```

模型测试涵盖已知半衰期、真实日历间隔、峰后最少月份、跨年峰值、零值、非衰减与边界拟合。
固定效应系数和聚类协方差与显式书籍虚拟变量回归独立核对。
完整流程测试涵盖格式分母、别名修正、缺失月份、零总量月份、人工审核门槛、排除作品、
空分片、输出图表，以及缺失分片时阻止最终合并。CHTC 测试使用隔离沙盒模拟文件传输和每个 R 阶段，不调用 HTCondor，不构建容器，也不提交真实作业。

参考接口：[data.table fread](https://rdatatable.gitlab.io/data.table/reference/fread.html)、
[Arrow Parquet](https://arrow.apache.org/docs/r/reference/write_parquet.html)、
[R 一维优化](https://stat.ethz.ch/R-manual/R-devel/library/stats/html/optimize.html)、
[CHTC DAGMan](https://chtc.cs.wisc.edu/uw-research-computing/htc/dagman-workflows/)。
