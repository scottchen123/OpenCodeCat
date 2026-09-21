# OpenCodeCat

桌面上的一只小猫，顺手看一眼用量。

平时就是一只像素小猫加一个月度百分比，不占地方，能拖到屏幕任意位置。鼠标放上去会展开，5 小时、周、月三档用量各一条进度。点一下弹出详情，能看到重置时间和完整额度。

> 在线介绍页：https://scottchen123.github.io/OpenCodeCat/

## 下载

macOS（Apple Silicon）：[点这里下载最新 dmg](https://github.com/scottchen123/OpenCodeCat/releases/latest)

进页面后下载 `OpenCodeCat-macOS-arm64.dmg`。

下载后双击打开，把 OpenCodeCat 拖进 Applications，再双击运行就行。菜单栏和 Dock 都不占图标，桌面上只有这只猫。

Windows 目前没有，这个版本只支持 macOS 13 及以上。

## 设置 key

第一次打开如果提示找不到 key，点详情面板右上角的齿轮：

- 名称：随便填，自己区分渠道用
- Key：粘贴进去，默认脱敏显示，点眼睛看全文
- 用量接口：默认已填好，换中转时改成对应地址就行

保存后自动刷新。key 只存本机，不会上传到任何地方。

也可以提前写好文件：

```bash
echo -n "你的key" > ~/.opencode-usage-key
chmod 600 ~/.opencode-usage-key
```

或者用环境变量 `OPENCODE_GO_API_KEY`。

## 用法

- 拖动：按住小猫拖，位置自动记住，下次打开还在原地
- 悬停：展开三档用量
- 单击：打开、关闭详情面板
- 右键：刷新、放回右上角、隐藏、退出

用量颜色：绿低于 40，黄低于 70，橙低于 90，红色 90 起。月度到 90% 会有一条提醒。

## 其他

- 每 60 秒自动刷一次，详情里也能点立即刷新
- 换中转地址时，只要回包里有 rolling、weekly、monthly 各自的 percent 就能直接用，缺字段会自动容错
- 齿轮里可以恢复默认设置

---

个人手搓的小工具，有问题提 Issue。
