# unityres
resource manager for unity slua

## 初始化

### res.initialize(cfg, option, callback)

* option.wwwlimit 实现了对WWW的资源设限。要>=1。意味着同时会启动几个WWW。
	
	* windows上测试结果为，当启动1000个WWW，可能会启动200个左右的线程，如果在editormode下启动10000个会提示too many thread崩溃

* option.useEditorLoad 如果设置true，则使用同步调用AssetDatabase.LoadAssetAtPath

* cfg 有assets.csv，assetcachepolicy.csv

* assets.csv 每行为assetinfo，格式为 { assetpath: xx, abpath: xx, type: xx, location: xx, cachepolicy: xx }，

	* 从assets.csv中读取，而assets.csv由打包程序生成。assets.csv以assetpath作为primary key，（当type为asetbundle时assetpath==abpath）

	* type 可能为 { assetbundle = 1, asset = 2, prefab = 3 }； location 可能为 { www = 1, resources = 2 }；

	* cachepolicy 指向assetcachepolicy.csv，解析后得到cache，为res.Cache 的一个实例。

* assetcachepolicy.csv 每行格式为{ name : xx, lruSize : xx }

* option.errorlog, option.debuglog 参数为(message), 如果为nil，在会调用lua的error

* callback 参数为(err)


## 加载

### res.load(assetinfo, callback)

* load后，这个asset会在assetinfo.cache.loaded中（即使load出错，这个asset为nil，也会进loaded里，这样方便load，free配对），如果不需要了需要调用res.free。

* callback 参数为(asset, err)

### res.loadmulti(assetinfos, callback)

* assetinfos是assetinfo一个sequence

* callback 参数为 (result) result为{ asset = asset, err = err }的一个sequence


### future = res.wwwloader.load(url, callback)

* callback 参数为 (www)

* future 是个LoadFuture对象，可调用future:cancel()，这样如果callback还没被调用，将不会再被调用。

## 释放

### res.free(assetinfo)

1. 如果这份资源还有其他load，则在assetinfo.cache.loaded中（cache里refcnt的）；

2. 如果没有其他load了但刚调用完free，会在assetinfo.cache.cached中等待lru；

3. 这样再等待一段时间，可能会被lru出去，cache中不再持有。


## 其他

* wwwloader的priority支持，assetbundle variant支持，等时机到了需要时写。

