## 资源管理实现和Addressable API

* [目录](/)
    1. [逻辑层的异步加载处理策略](/usage.md)
    2. [资源管理实现和Addressable API](/impl.md)
    3. [统一的缓存管理](/pool.md)
    4. [自动化的打包策略](/pack.md)

### Addressable 的 API 设计

接上一篇 逻辑层的异步加载处理策略，当时设计 api 时没有东西可以参考，现在 unity 出了 Addressable Assets，正好对照反省一下，我们来看看它的核心 api 调用逻辑：

```cs
asyncOperationHandle=   LoadAssetAsync（key）//   InstantiateAsync，LoadSceneAsync
asyncOperationHandle.compelte   +=   callback

Release(asyncOperationHandle)
```

可以看到跟我们 loader 的设计基本一样。核心概念就是：直接根据 key 来返回资源，而不用管这个资源是如何打包的。把资源的打包 bundle 策略跟资源的使用完全隔离，让它们互不影响。怎么实现呢？

### 资源管理的引用计数实现

#### 错误方式：使用 c# 的 gc，在 Finalize 函数里去释放资源。

原理是当 c# 的对象被 GC 的时候，会回调对象的 Finalize 函数。在这里通知 c++ 去释放资源。但其实涉及到：

<1>系统资源比如 File Handle，这种操作系统管理的每个进程只能开启有限个文件句柄的资源，还是尽早释放的好，尽早释放还能让 OS 释放文件内容缓存的内存。
    
<2>另一个系统比如 c++ 引擎系统的大对象，因为 c# 管理的对象内部只保存了资源对象指针，不占什么空间，GC 又不能直接管理不到 C++ 里的资源对象。
等它触发 GC 就太慢了。可以参考 [Dispose vs Finalize](http://dotnetmentors.com/c-sharp/implementing-finalize-and-dispose-of-net-framework.aspx)

#### 正确方式：基于引用计数

这里又分两种，一种是外部依赖度计数，一种是直接依赖度计数，以下图中比如 C 1，表示资源是 C，计数是 1。

![](/alldep.png)

![](/directdep.png)

* 外部依赖度的计数是此资源有多少 user 依赖它。
    
* 直接依赖度计数是此资源有多少其他资源或 user 直接依赖它，就是跟它相连的线个数。
    

Addressable 使用的是外部依赖度计数。我们用的直接依赖读计数。

这里的原因是 Addressable 不做任何的缓存管理，而我们集成了缓存的管理。
也因为对 Addressable 来说 AssetBundle 是隐藏不可见的，
而我们把 AssetBundle 也视为一个 asset 了，可以加载返回一个 loader（这样可以对 assetbundle 做缓存策略管理，同时我们对 Scene 的加载没放在这里，而放在了上层）。
直接依赖计数的具体实现可参考 [res.lua](https://github.com/stallboy/unityres/blob/master/res/res.lua)


### Asset 与 AssetBundle 的释放策略

另外一个看 Addressable 源码想验证的就是：asset 与包含它的 bundle 的具体的释放策略。结论是跟我们一致。  

#### 1，当持有 asset 时，包含它的 bundle 不能释放。

假设我们从 bundle 里加载得到 asset1 后，bundle.Unload(false)。

则当下次加载另一个 asset2，我们假设 asset2 依赖 asset1，加载这个 asset2 时，unity 会再次加载 asset1 所在的 bundle，再加载 asset1，而这个 asset1 因为和上次的 asset1 来自 2 次不同加载的 bundle。导致 asset1 在内存中有 2 份。

#### 2，当持有的 asset 释放时，不能 UnloadAsset

Unity 的确提供了 Resources.UnloadAsset，但别用。正确的做法是 等 bundle 里所有的 asset 都没有被引用时，释放 bundle 和所有的 asset。即 bundle.Unload(true)。为什么呢？  

假设 bundle 里有一个 ui 的 prefab，有一个 sprite，2 个 asset；prefab 包含这个 sprite。注意这个 prefab 对 sprite 的依赖，并没有被引用计数表达出来，所以当 user 使用着这个 prefab，然后先加载使用这个 sprite 然后再释放。如果我们 UnloadAsset，则 prefab 依赖的 sprite 就没了。表现出来是 ui 有时图标消失，显示白片。

Addressable 里的 AssetBundleProvider.cs, BundledAssetProvider.cs 里的 Release 可看到这个策略。我们的是在 [Cache.lua](https://github.com/stallboy/unityres/blob/master/res/Cache.lua) 的\_realfree 里。  

其实这个 bundle 的释放策略也暗含了打包策略：最好不要把很多 asset 打到一个巨大的 bundle 里。因为一个 bundle 的 asset 不再被使用后不会立马释放，而是要等到 bundle 里所有的 asset 都不被使用后才可能释放。

### 总结

介绍了 Addressable Assets 的核心概念，实现方式，以及跟我们实现方案的对比，主要的区别有 2 个：

1.  我们把 bundle 作为 asset，没有完全隐藏这个概念，Addressable 把 bundle 完全隐藏。
    
2.  Addressable 不做资源的缓存策略管理，释放就真释放。缓存交给了上层来做。而我们在底层做了 统一的缓存设计。
    

这两个差别也导致了引用计数上实现的差别。Addressable 缺少缓存设计，所以真正用的时候还得增加一层缓存设计，

下篇来介绍统一的缓存设计。  