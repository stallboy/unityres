## 统一的缓存管理

* [目录](/index.md)
    1. [逻辑层的异步加载处理策略](/usage.md)
    2. [资源管理实现和Addressable API](/impl.md)
    3. [统一的缓存管理](/pool.md)
    4. [自动化的打包策略](/pack.md)
    

接上一篇 资源管理，Addressable Assets，统一的缓存管理是我们跟 Addressable 的主要区别，先上总体图

![](/arch.jpg)


### Cache 是资源对象缓存，减少资源重复加载开销 

```lua
function Cache:setCachePolicy(maxsize, timeout_seconds)
```

此 cache 最多缓存额外 maxsize 个资源，这些额外的资源在 timeout _seconds 秒后也被释放。参考 [Cache.lua](https://github.com/stallboy/unityres/blob/master/res/Cache.lua)  

注意这里不是只有一个全局的 Cache，而是分类了。每个 assetpath 唯一对应一个 cache，这种对应关系被记录在我们的 assetinfo 和 cachepolicy 表中，这两个表是我们打 assetbundle 时生成的。

具体实际的缓存策略如下：

```lua
--- 战斗音效，ui音效，音乐
setpolicy(assetcachepolicy.fightsound, 100, 50)
setpolicy(assetcachepolicy.uisound, 3, 15)
setpolicy(assetcachepolicy.sound, 0)

--- ui
setpolicy(assetcachepolicy.ui, 0)
--- altas 之前是32，15导致在panelfashion界面来回持续切换tab页时，SetSprite就会重新加载sprite，unity c++就持续分配内存，GetTotalAllocatedMemoryLong持续提高
--- 这里cache设置高一点，避免持续分配
setpolicy(assetcachepolicy.atlas, 180, 30)
setpolicy(assetcachepolicy.emoticonanimator, 16, 15)
--- 这个是人物头像图片，角色有100个好友，所以这里设置100
setpolicy(assetcachepolicy.netsprite, 100, 15, {100, 15})

--- anim， shader
setpolicy(assetcachepolicy.anim, 8, 10)
setpolicy(assetcachepolicy.shader, 4, 15)

--- prefab
setpolicy(assetcachepolicy.avatar, 0)
setpolicy(assetcachepolicy.sfx, 0)
```

### Pool 是场景对象缓存，减少 prefab 实例化开销

```lua
function Pool:setCachePolicy(max_extra_go_size, max_extra_res_size, timeout_seconds)
```

此 pool 最多额外缓存 max _extra _go _size 个 GameObject，这个额外缓存的 GameObjct 最多额外占用 max _extra _res _size 个资源，这些额外缓存在 timeout _seconds 后被释放。参考 [Pool.lua](https://github.com/stallboy/unityres/blob/master/res/Pool.lua)  

同样这里也不是一个全局性的 Pool，而是分类。要得到 GameObject 必须提供 pool，使用接口在 [loader.lua](https://github.com/stallboy/unityres/blob/master/res/loader.lua) 里：

```lua
local loader = makeGameObj(pool, assetinfo)
```

具体的缓存策略如下：

```lua
mkpool("character", 20, 5, 15)
mkpool("attachment", 100, 32, 20)

mkpool("sfx", 20, 10, 10)
--- 自己的技能特效，就高低内存都多多缓存，并且不随时间释放
mkpool("myhero_sfx", 50, 35, nil, { 50, 35 })
mkpool("otherhero_sfx", 380, 300, 30)
mkpool("other_sfx", 20, 10, 15)

mkpool("sceneobj", 10, 5, 10)
```

```lua
local panelpool = Pool:new("panel", nil, 0, 0)
local worldpanelpool = Pool:new("worldpanel", nil, 0, 0)
```

```lua
resmgr.setCachePolicyParam(uimgr.component_singltonpool, { 1, 20 }, { 1, 3 })
resmgr.setCachePolicyParam(uimgr.component_multipool, { 40 }, { 20 })
```

有些细节：

1. pool 下面还有 cache 做缓存，双层缓存，但 prefab 的 cache 都是 0，都在 pool 里去配置缓存，因为：在最靠近 user 的地方配缓存。

2. 看到 ui 的 pool 缓存都是 0，因为上层还有一层 lua 对象的缓存，这个 lua 对象包含 GameObject，，单例的 UI 界面只缓存一个，而多例的 worldpanel 缓存 40 个。

### 统一的缓存策略

好处：

1. 其他逻辑程序不用考虑缓存策略，而是在一个集中的地方被做优化的程序统一管理。

2. 可以附加进一步的自适应策略，比如 OS 发出低内存警告后，所有的缓存策略 max _size 都除以 2，甚至把额外缓存全部清掉。
