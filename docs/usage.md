## 逻辑层的异步加载处理策略

* [目录](/index.md)
    1. [逻辑层的异步加载处理策略](/usage.md)
    2. [资源管理实现和Addressable API](/impl.md)
    3. [统一的缓存管理](/pool.md)
    4. [自动化的打包策略](/pack.md)

这篇从对  异步加载接口和 处理策略开始讨论  

### 什么是同步加载，异步加载？

1，同步

```lua
local asset = load(assetpath)
```

2，异步

```lua
loadAsync(assetpath, callback)

local function callback(asset)
    -- xxx
end
```

### 为什么需要异步加载？

这是因为资源加载需要读盘，我们这先不考虑读取时间，只考虑寻址，
读硬盘的寻址时间13.7ms [hd seek time](https://manybutfinite.com/post/what-your-computer-does-while-you-wait/)
这基本上就是半帧时间就过去了，游戏线程会进入block状态，等待io完成，画面会卡。

当然即使你在手机上用同步加载小的资源，也许感觉不出来，因为手机是ssd，
ssd的寻址时间 [ssd seek time](https://www.google.com/search?q=ssd+seek+time)
差不多是0.1ms，比读硬盘好100倍，但也是10的5次方级别的cpu指令时间，也够浪费的。  

因此武林只提供了异步加载的接口，不支持同步加载。但下一个问题是异步加载如何管理，管理的复杂性可能影响了部分游戏对异步的采用。

### 异步加载的基本管理  

1. 错误做法：在需要时直接 free(assetpath)，如下

    ```lua
    loadAsync(assetpath, callback1)
    loadAsync(assetpath, callback2)
    
    free(assetpath)
    ```
    
    问题1：因为这 2 个loadAsync可能在系统的不同地方被调用，注意这里free并不是真的释放，底层要依赖引用计数（下一篇文章介绍），
    free到底要取消callback1，还是callback2？
    
    问题2：unity 也不太支持asset还没加载完的时候free，所以其实真正的free得在 callback 里做

2. 错误做法：在 callback 的回调里 free，如下

    ```lua
    loaded = false
    loadAsync(assetpath, callback)
    
    local function callback(asset) 
            if asset在逻辑上仍然需要 then
                    loaded = true
                    --使用asset
            else
                    free(asset)
            end
    end
    
    local function OnDestroy()
            if loaded then
                    free(asset)
            end
    end
    ```
    
    “asset在逻辑上仍然需要”如何判断？ 是还在这个场景中？这个 ui 仍然打开着？
    这种问题很多，因为资源加载完成的时刻可以是游戏的任意时刻，你的回调里要考虑所有的全部的游戏状态吗？太难了。

3. 正确做法，加入一层抽象，变异步为逻辑上同步

    ```lua
    local loader = makeAsset(assetpath)
    loader.load(callback)
    
    loader.free()
    ```
    
    不想要这个资源的时候调用 loader.free()。底层实现如果这个asset已经加载上来，那么就释放，
    如果还没加载上来，那么等它加载上来时候自动free，不再调用callback。
    参考 [loader.lua](https://github.com/stallboy/unityres/blob/master/res/loader.lua)
    

以上我们定义了基础的 api，但有一些基于此 api 的通用的模式，我觉得各个项目是相同的，可以公用，这里也提取成相应的底层接口。
根据武林的开发经验，有 4 种异步加载的组合的这种需求。

### 四种异步加载的组合模式  

1. 游戏刚启动的时候preload所有永远不释放的资源

    比如跳跃曲线，各种 shader，这样游戏运行中的逻辑写的时候就当这些asset已经存在，直接用不用异步加载了。
    参考 [async.lua](https://github.com/stallboy/unityres/blob/master/res/async.lua)
    
    ```lua
    async.parallel(load(x1), load(x2), ...)(alldone)
    ```

2. 需要多个资源同时加载上来后，才一起使用。

    比如加载过场动画，需要过场动画的prefab和动态绑定角色的GameObject都加载上来后，才能开始播放过场动画。
    参考loader.lua里的makeMulti。
    
    makeAsset返回资源对象loader，
    
    makeGameObject返回一个实例化的场景对象loader（addressable api 把场景对象叫做 Instance，这里直接用 GameObject），
    
    makeMulti是个复合节点的loader，用composite模式，它在两个子loader都完成后才callback。

    ```lua
    local loader = makeMulti( makeAsset(x1), makeAsset(x2) )
    ```

3. 在新的资源加载过程中，使用老资源，避免异步过程空白期老资源被释放。

    比如在UI上设置Sprite

    ![](/attachment.png)

    接口为
    ```lua
    --------------------------------------------------------
    --- loader之上是Attachment
    --- 每个attackey，只对应一个go 或者 asset
    --- 如果已经attach了一个a，要attach另一个b，只有在b请求加载完成后才释放正在用的a，避免加载过程中出现空白。
    function Attachment:attach(attachkey, thisloader, callback, ...)
    ```

    参考 [Attachment.lua](https://github.com/stallboy/unityres/blob/master/res/Attachment.lua)

4. 人物有很多组件组成，并且各个组件加载上来后要挂到特定的挂点上
    
    ![](/avatar.png)
    
    接口为
    ```lua
    --------------------------------------------------------
    --- Avatar，做2件事情
    --- 1，保证所有attach都加载上来后整体显示，而不会单个显示出来，比如先显示个头，再显示身体就太怪了
    --- 2，Avatar有个骨骼，多个部件。部件有挂点attachpoint(可以为nil)，必须等skeleton加载完后才挂到attachpoint上
    --- 同时它本身又是一个loader可以attach 到avatar上。
    function Avatar:new(skeletonLoader)
     
    --------------------------------------------------------
    --- newParts参数结构为： { <partKey>: <part>, }
    --- part结构要包含：{attachpoint=xx, loader=xx}，建议类里有Render函数，在allAttachDone回调里依次调用各个part的Render
    --- 每次attachParts要free掉之前的part，所以每次part要新建，跟上次不要共用
    --- 这里直接保存newParts为loading，所以newParts也要新建
    function Avatar:setParts(newParts)
    ```
    
    参考 [Avatar.lua](https://github.com/stallboy/unityres/blob/master/res/Avatar.lua)
    注意这个Avatar也是loader，是个复合loader
    加上之前的makeAsset, makeGameObject, makeMulti返回的loader，
    共有4种loader，2个原子loader，2个Composite模式的组合loader，可以组织成树，非常的灵活。

### 总结

有此基础的loader api和这四个组合模式的api，所有涉及异步加载的地方，全部变成了逻辑上的同步调用。

下一篇写一写 [资源加载的底层逻辑，以及跟addressable api的对比](/impl.md)
