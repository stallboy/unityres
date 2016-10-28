# unityres
resource manager for unity slua




## 初始化

### res.initialize(cfg, assetbundleLoaderLimit, callback)

* assetbundleLoaderLimit 实现了对WWW或LoadFromFileAsync的资源设限。要>=1。意味着同时会启动几个WWW或LoadFromFileAsync。

  windows上测试结果为，当启动1000个WWW，可能会启动200个左右的线程，如果在editormode下启动10000个会提示too many thread崩溃

* cfg 有assets.csv，assetcachepolicy.csv

* assets.csv 每行为assetinfo，格式为 { assetpath: xx, abpath: xx, type: xx, location: xx, cachepolicy: xx }，

  * 从assets.csv中读取，而assets.csv由打包程序生成。assets.csv以assetpath作为primary key，（当type为asetbundle时assetpath==abpath）

  * type 可能为 { assetbundle = 1, asset = 2, prefab = 3 }； location 可能为 { www = 1, resources = 2 }；

  * cachepolicy 指向assetcachepolicy.csv，解析后得到cache，为res.Cache 的一个实例。

* assetcachepolicy.csv 每行格式为{ name : xx, lruSize : xx }

* callback 参数为(err)


## 加载

### res.load(assetinfo, callback)

* load后，这个asset会在assetinfo.cache.loaded中（即使load出错，这个asset为nil，也会进loaded里，这样方便load，free配对），如果不需要了需要调用res.free。

* callback 参数为(asset, err)

## 释放

### res.free(assetinfo)

1. 如果这份资源还有其他load，则在assetinfo.cache.loaded中（cache里refcnt的）；

2. 如果没有其他load了但刚调用完free，会在assetinfo.cache.cached中等待lru；

3. 这样再等待一段时间，可能会被lru出去，cache中不再持有。真正释放

## Pool

针对prefab，我们可以通过

* Pool:new(name, max_extra_go_size, max_extra_res_size, poolparent, pool_by_setposition, destroycallback)来初始化，
* Pool:load(prefabassetinfo, callback)来访问，
* Pool:free(prefabassetinfo, gameobject, attachedData)来释放，

用了prefab，底层的Cache的lruSize就可以设置为0。在这一层控制场景对象和资源的缓存。
这里Pool:load的callback(go, err)如果go为nil，则不需要调用Pool:free。

## 其他

assetinfo分为

* asset，sprite：包括texture,audio,material...，无需Instantiate
* prefab：asset sprite的组装件，是一堆引用和配置，Instantiate 进入场景
* assetbundle：由asset,sprite,prefab打包而成。会依赖其他assetbundle

---

load时都会增加自己和所有依赖的引用计数

free时减少自己和所有依赖的引用计数，计数为0时

* asset,sprite: Resource.UnloadAsset，如果之后还有引用会重新reload，但editor下好像没及时更新渲染。If there are any references from game objects in the scene to the asset and it is being used then Unity will reload the asset from disk as soon as it is accessed.
* prefab: free时什么都不做，但它会触发包含自己的assetbundle的free，最终通过assetbundle:Unload(true)来释放
* assetbundle: assetbundle:Unload(true)

---

unloadUnusedAssets时，针对lua对asset和prefab的引用，mono知道吗？
知道，slua，通过ObjectCache使得slua在有引用A时。A也始终在csharp的ObjectCache里。
lua的 metamethod __gc 来触发ObjectCache里的remove。
从而实现了2个gc，lua gc和c# gc的沟通。

---

逻辑应该如何调用res.load, res.free？
应该平衡，调了多少load，就调多少free

----

根据unity自己搞得AssetBundleManager，www取出来后assetbundle后可以立马www.dispose。

----

prefab包含资源的引用，
unity场景文件包含的是对prefab有修改Modifications的字段的记录，如果直接fbx拖到场景里，其实内部也是prefab，你可以直接

    var go = AssetDatabase.LoadAssetAtPath<GameObject>("Assets/Monster/Shark/@SharkModel.FBX");
    var g = GameObject.Instantiate(go);

assetbundle的依赖 可由 AssetbundleManifest 来提供api 得到。
asset之间的依赖，则没有提供api，内部根据externals的链接来得到依赖，应用无法得知。

----

unity的文件格式 可做参考 [Serialized file format]

[Serialized file format]: https://github.com/ata4/disunity/wiki/Serialized-file-format

----

针对unity资源相关api的测试 [unitytest]

[unitytest]: https://github.com/stallboy/unitytest

----

assetBundleLoader的priority支持，assetbundle variant支持，等时机到了需要时写。
