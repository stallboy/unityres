# unityres
resource manager for unity slua 

## 初始化

### res.initialize(wwwlimit, editormode, abpath2assetinfo, errorlog)

* wwwlimit 实现了对WWW的资源设限。要>=1。意味着同时会启动几个WWW。
	
	* windows上测试结果为，当启动1000个WWW，可能会启动200个左右的线程，如果在editormode下启动10000个会提示too many thread崩溃

* editormode 如果设置true，则使用同步调用AssetDatabase.LoadAssetAtPath 

* abpath2assetinfo 由assetinfo.csv直接生成。当加载有依赖项的assetbundle时方便cache依赖的assetbundle。

* errorlog 参数为(message), 如果为nil，在会调用lua的error


### res.load_manifest(assetinfo, callback)

* 这个不会位于cache中，需要一旦加载，永远都在内存中

* 如果是editormode，则不需要调用这个函数

* assetinfo 格式为 { assetpath: xx, abpath: xx, type: xx, location: xx, cache: xx }，

	* 从assetinfo.csv中读取，而assetinfo.csv由打包程序生成。assetinfo.csv以assetpath作为primary key，（当type为asetbundle时assetpath==abpath）

	* type 可能为 { assetbundle = 1, asset = 2, prefab = 3 }； location 可能为 { www = 1, resources = 2 }；

	* cache 为Cache类的一个instance，里面实现了lru。

* callback 参数为 (err, asset) 

	* err为nil时，asset不为nil，代表成功

	* err不为nil时，是错误原因字符串，asset为nil，代表失败


## 加载

### future = res.load(assetinfo, callback)

* load成功后，这个asset会在assetinfo.cache.loaded中，如果不需要了，需要调用res.free。注意要 if err == nil 判断成功后再free。不然的话可能free掉其他地方的load。

* future 是个LoadFuture对象，可调用future:cancel()，这样如果callback还没被调用，将不会再被调用。


### future = res.wwwloader.load(url, callback)

* callback 参数为 (www)

## 释放

### res.free(assetinfo)

1. 如果这份资源还有其他load，则在assetinfo.cache.loaded中（cache里refcnt的）；

2. 如果没有其他load了但刚调用完free，会在assetinfo.cache.cached中等待lru；

3. 这样再等待一段时间，可能会被lru出去，cache中不再持有。

## TODO

* wwwloader的priority支持，等时机到了需要时写。

* assetbundle variant支持，
