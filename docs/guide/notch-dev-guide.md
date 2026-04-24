# Notch App 开发指南

基于对 NotchDrop 的通读整理，抽取 notch 类应用的通用设计模式与关键实现。不包含 AOS 业务逻辑，聚焦「如何把一个 SwiftUI 视图稳定地挂在刘海周围并响应悬停 / 点击 / 拖拽」。

完整参考：playground/NotchDrop/

---

## 0. 名词约定

| 术语 | 含义 |
|---|---|
| 物理刘海 (device notch) | 硬件黑条所在矩形，由系统 API 报告 |
| 刘海面板 (notch panel) | App 自己渲染的那个从刘海下方展开的浮层 |
| 热区 (hit rect) | 鼠标进入触发 popping / open 的矩形，一般是物理刘海 + 少量 inset |

三种状态：

```
closed ──hover──▶ popping ──click / drag──▶ opened
   ▲                                        │
   └────────────── leave / outside ─────────┘
```

---

## 1. 进程与 Activation Policy

### 1.1 Accessory policy

Notch 应用没有 Dock icon、也没有菜单栏条目的经典窗口。启动后立即切换 policy：

```swift
NSApp.setActivationPolicy(.accessory)
```

- `.accessory`：无 Dock 图标，但可以持有 key window 接收输入
- 不用 `.prohibited`：那样 `NSApp.activate(...)` 不生效，面板无法获得焦点接受键盘事件

### 1.2 单实例自杀 (pidfile)

Notch 悬浮在屏幕最上层，多实例并存会视觉叠加。处理办法：启动时写入 pid 文件，启动过程中检测旧进程并 `terminate`，运行期每秒校对 pid 文件内容，不是自己就退出。

```swift
// main.swift 启动阶段
let pidFile = documentsDirectory.appendingPathComponent("ProcessIdentifier")
if let prev = try? String(contentsOf: pidFile, encoding: .utf8),
   let pid = Int(prev),
   let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
    app.terminate()
}
try String(NSRunningApplication.current.processIdentifier)
    .write(to: pidFile, atomically: true, encoding: .utf8)
```

```swift
// 运行期 AppDelegate
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
    let pid = String(NSRunningApplication.current.processIdentifier)
    let content = (try? String(contentsOf: pidFile)) ?? ""
    if pid.trimmed.lowercased() != content.trimmed.lowercased() {
        NSApp.terminate(nil)
    }
}
```

### 1.3 自身可执行文件被删 → 退出

开发期频繁替换二进制，残留旧进程容易误导状态。用 `DispatchSource.makeFileSystemObjectSource(eventMask: .delete)` 监听 `argv[0]`，被删即 `exit(0)`。

```swift
let executablePath = ProcessInfo.processInfo.arguments.first!
let fd = open(executablePath, O_EVTONLY)
let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .delete)
src.setEventHandler { if src.data == .delete { src.cancel(); exit(0) } }
src.resume()
```

---

## 2. 屏幕与物理刘海识别

### 2.1 检测屏幕是否有刘海

macOS 通过 `NSScreen.safeAreaInsets.top > 0` 暴露刘海的存在。宽度要借助左右两块 auxiliary area：

```swift
extension NSScreen {
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else { return .zero }
        let h = safeAreaInsets.top
        let leftPad = auxiliaryTopLeftArea?.width ?? 0
        let rightPad = auxiliaryTopRightArea?.width ?? 0
        guard leftPad > 0, rightPad > 0 else { return .zero }
        let w = frame.width - leftPad - rightPad
        return CGSize(width: w, height: h)
    }
}
```

### 2.2 选出「正确」屏幕

多显示器时，始终选择内建屏幕（物理刘海只存在于内建屏幕）。无刘海机型 fallback 到 `NSScreen.main` 并给一个虚拟刘海尺寸（如 150×28）用于开发调试。

```swift
extension NSScreen {
    var isBuildinDisplay: Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = deviceDescription[key],
              let rid = (id as? NSNumber)?.uint32Value else { return false }
        return CGDisplayIsBuiltin(rid) == 1
    }
    static var buildin: NSScreen? { screens.first { $0.isBuildinDisplay } }
}
```

### 2.3 热插拔 / 分辨率变化

屏幕数量、分辨率、内建屏连接状态任何一个变化都可能让 window 的 frame 错位。监听：

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(rebuildApplicationWindows),
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)
```

响应里销毁旧 `NSWindowController` 并重建。

---

## 3. 浮层窗口

### 3.1 NSWindow 子类

关键属性：

```swift
class NotchWindow: NSWindow {
    override init(...) {
        super.init(...)
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hasShadow = false
        collectionBehavior = [
            .fullScreenAuxiliary,  // 全屏 app 时也显示
            .stationary,           // Mission Control 不把它挪到任何桌面
            .canJoinAllSpaces,     // 所有 Space 都出现
            .ignoresCycle,         // cmd-` 不轮到它
        ]
        level = .statusBar + 8     // 盖住菜单栏、dock 提示
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

几个容易踩的点：

- `level = .statusBar + 8`：比菜单栏略高一档，但低于系统级的抓屏 / 输入法候选框。直接用 `.screenSaver` 会压过系统 UI
- `collectionBehavior` 四项缺一不可：少了 `.fullScreenAuxiliary` 进全屏 app 就消失；少了 `.canJoinAllSpaces` 换 Space 就不见
- `hasShadow = false`：系统投影和自绘刘海形状冲突，阴影由 SwiftUI 内部 `.shadow` 按状态加

### 3.2 定位 Window

Window 的 frame 不是只覆盖刘海那一小块——而是覆盖屏幕顶部一整条。这样 SwiftUI 内部可以自由摆放面板、hover 区域，不受 window frame 限制。

```swift
private let notchHeight: CGFloat = 200  // 面板完全展开时最多占的高度
let topRect = CGRect(
    x: screen.frame.origin.x,
    y: screen.frame.origin.y + screen.frame.height - notchHeight,
    width: screen.frame.width,
    height: notchHeight
)
window.setFrameOrigin(topRect.origin)
window.setContentSize(topRect.size)
```

Style mask：

```swift
NotchWindow(
    contentRect: screen.frame,
    styleMask: [.borderless, .fullSizeContentView],
    backing: .buffered,
    defer: false,
    screen: screen
)
```

### 3.3 NSHostingController 挂 SwiftUI

```swift
class NotchViewController: NSHostingController<NotchView> {
    init(_ vm: NotchViewModel) { super.init(rootView: .init(vm: vm)) }
}
contentViewController = NotchViewController(vm)
```

SwiftUI 内部通过 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` 占满 window，再用 ZStack 按状态摆放刘海形状与面板内容。

### 3.4 生命周期与销毁

重建 window 时必须彻底释放：取消所有 Combine 订阅、置空 `contentViewController`、close 并置空 `window`。否则多屏幕切换几次内存会堆积 view model。

```swift
func destroy() {
    vm?.destroy()          // 内部 cancellables.forEach { $0.cancel() }
    vm = nil
    window?.close()
    contentViewController = nil
    window = nil
}
```

---

## 4. 状态机与 ViewModel

### 4.1 最小状态集

```swift
enum Status { case closed, popping, opened }
enum OpenReason { case click, drag, boot, unknown }
enum ContentType { case normal, menu, settings }
```

`popping` 是一个短暂的中间态：用户鼠标进入热区，刘海「微微鼓起」作为即将展开的反馈。click 或 drag 进入 opened；鼠标离开则回落 closed。这个三态对 UX 非常关键——没有 popping，用户一靠近就突然展开很惊吓。

### 4.2 ObservableObject

```swift
class NotchViewModel: NSObject, ObservableObject {
    @Published private(set) var status: Status = .closed
    @Published var openReason: OpenReason = .unknown
    @Published var contentType: ContentType = .normal
    @Published var deviceNotchRect: CGRect = .zero   // 物理刘海位置
    @Published var screenRect: CGRect = .zero        // 所在屏幕 frame
    @Published var notchVisible: Bool = true

    let animation: Animation = .interactiveSpring(
        duration: 0.5, extraBounce: 0.25, blendDuration: 0.125
    )
    let notchOpenedSize = CGSize(width: 600, height: 160)
    let dropDetectorRange: CGFloat = 32
    let inset: CGFloat  // 无物理刘海时为 0，有刘海时 -4，扩大热区补偿边缘误差

    func notchOpen(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        contentType = .normal
        NSApp.activate(ignoringOtherApps: true)
    }
    func notchClose() { /* ... */ }
    func notchPop()   { status = .popping }
}
```

### 4.3 派生几何

面板展开矩形和「头部条（visually aligning with device notch）」矩形由 ViewModel 按屏幕 + 物理刘海派生，不存成状态：

```swift
var notchOpenedRect: CGRect {
    .init(
        x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
        y: screenRect.origin.y + screenRect.height - notchOpenedSize.height,
        width: notchOpenedSize.width,
        height: notchOpenedSize.height
    )
}
var headlineOpenedRect: CGRect {
    .init(
        x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
        y: screenRect.origin.y + screenRect.height - deviceNotchRect.height,
        width: notchOpenedSize.width,
        height: deviceNotchRect.height
    )
}
```

---

## 5. 全局事件监听

### 5.1 NSEvent global + local 双通道

`NSEvent.addGlobalMonitorForEvents` 只在 app **不是** key window 时收事件；`addLocalMonitorForEvents` 只在是 key window 时收。两个都要装，回调里跑同一份 handler：

```swift
public class EventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    public func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        localMonitor  = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handler(e); return e
        }
    }
    public func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor  { NSEvent.removeMonitor(l) }
        globalMonitor = nil; localMonitor = nil
    }
    deinit { stop() }
}
```

### 5.2 需要订阅的事件

| Mask | 用途 |
|---|---|
| `.mouseMoved` | 鼠标进入热区 → pop；离开 → close |
| `.leftMouseDown` | 热区外点击 → close；物理刘海内点击 → 折叠 |
| `.leftMouseDragged` | 拖拽开始的旁路（文件拖拽由 SwiftUI `.onDrop` 主处理） |
| `.flagsChanged` | Option 等修饰键状态，驱动二级交互（如「Option + 点击 × 删除」） |

全部用 `CurrentValueSubject` / `PassthroughSubject` 暴露给 ViewModel：

```swift
let mouseLocation = CurrentValueSubject<NSPoint, Never>(.zero)
let mouseDown     = PassthroughSubject<Void, Never>()
let optionKeyPress = CurrentValueSubject<Bool, Never>(false)
```

### 5.3 ViewModel 订阅样式

```swift
events.mouseLocation
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
        guard let self else { return }
        let p = NSEvent.mouseLocation
        let inHot = deviceNotchRect.insetBy(dx: inset, dy: inset).contains(p)
        if status == .closed, inHot { notchPop() }
        if status == .popping, !inHot { notchClose() }
    }
    .store(in: &cancellables)

events.mouseDown
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in
        guard let self else { return }
        let p = NSEvent.mouseLocation
        switch status {
        case .opened:
            if !notchOpenedRect.contains(p) { notchClose() }
            else if deviceNotchRect.insetBy(dx: inset, dy: inset).contains(p) { notchClose() }
        case .closed, .popping:
            if deviceNotchRect.insetBy(dx: inset, dy: inset).contains(p) { notchOpen(.click) }
        }
    }
    .store(in: &cancellables)
```

注意：`.opened` 下的「面板外点击」不能一概而论，要分两段——面板外 close；物理刘海内 close（等价于再点一次刘海收起）。

### 5.4 订阅销毁

`cancellables: Set<AnyCancellable>` 放在 ViewModel 上。destroy 时：

```swift
func destroy() {
    cancellables.forEach { $0.cancel() }
    cancellables.removeAll()
}
```

---

## 6. 刘海形状

难点在于「打开时的圆角刘海过渡」——两侧圆弧方向是 **反的**（外凸 → 内凹）。做法是画一个圆角矩形，用 `blendMode(.destinationOut)` 把两个外凸圆角「挖掉」。

```swift
Rectangle()
    .foregroundStyle(.black)
    .frame(width: w, height: h)
    .clipShape(.rect(bottomLeadingRadius: r, bottomTrailingRadius: r))
    .overlay {
        // 左肩：画一块黑色方块做 base，上面盖一个 topTrailing 圆角的白色矩形做 mask
        ZStack(alignment: .topTrailing) {
            Rectangle().frame(width: r, height: r).foregroundStyle(.black)
            Rectangle()
                .clipShape(.rect(topTrailingRadius: r))
                .foregroundStyle(.white)
                .frame(width: r + spacing, height: r + spacing)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: -r - spacing + 0.5, y: -0.5)
    }
    .overlay { /* 右肩镜像 */ }
```

三个细节：

- `compositingGroup()` 必须有，`blendMode` 才会被隔离作用在这个 ZStack 内部
- `offset(x: ..., y: -0.5)` 的半像素修正是为了抗锯齿边线和下方真实黑色矩形合缝时出现的 1px 漏光
- 圆角半径 `r` 与 `spacing` 要跟外层面板的 corner radius 协同（closed / opened / popping 各一套）

size 和 cornerRadius 都随状态过渡：

```swift
var notchSize: CGSize {
    switch vm.status {
    case .closed:  return .init(width: vm.deviceNotchRect.width - 4, height: vm.deviceNotchRect.height - 4)
    case .opened:  return vm.notchOpenedSize
    case .popping: return .init(width: vm.deviceNotchRect.width, height: vm.deviceNotchRect.height + 4)
    }
}
var notchCornerRadius: CGFloat {
    switch vm.status { case .closed: 8; case .opened: 32; case .popping: 10 }
}
```

外层 `.animation(vm.animation, value: vm.status)` 把 size / cornerRadius 的过渡一起交给 SwiftUI spring。

---

## 7. 打开 / 关闭动画 + 触觉反馈

### 7.1 Spring animation

一份配置全局共用，避免各处不一致：

```swift
let animation: Animation = .interactiveSpring(
    duration: 0.5, extraBounce: 0.25, blendDuration: 0.125
)
```

### 7.2 面板内容的 transition

面板从刘海下方「掉下来 + 放大 + 淡入」：

```swift
content
    .transition(
        .scale.combined(with: .opacity)
              .combined(with: .offset(y: -vm.notchOpenedSize.height / 2))
              .animation(vm.animation)
    )
```

### 7.3 淡出延迟

收起后先保留剪影 0.5s 再彻底隐藏，避免视觉跳跃：

```swift
$status
    .debounce(for: 0.5, scheduler: DispatchQueue.global())
    .filter { $0 == .closed }
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in withAnimation { self?.notchVisible = false } }
    .store(in: &cancellables)
```

### 7.4 Taptic Engine

`popping` 给一次 level-change，用 `throttle` 防抖：

```swift
$status
    .filter { $0 == .popping }
    .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: false)
    .sink { [weak self] _ in
        guard NSEvent.pressedMouseButtons == 0 else { return }
        self?.hapticSender.send()
    }
    .store(in: &cancellables)

hapticSender
    .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: false)
    .sink { _ in
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
```

---

## 8. 拖拽检测

文件拖拽要在 closed 状态被触发展开。用户还没 drop 就要开。做法：在刘海下方铺一块**接近透明**的 drop 区域，onDrop 回调强制返回 `true`（不真的接收）：

```swift
RoundedRectangle(cornerRadius: notchCornerRadius)
    .foregroundStyle(Color.black.opacity(0.001))  // 0.001 是 AppKit 命中测试的下限
    .contentShape(Rectangle())
    .frame(
        width: notchSize.width + vm.dropDetectorRange,
        height: notchSize.height + vm.dropDetectorRange
    )
    .onDrop(of: [.data], isTargeted: $dropTargeting) { _ in true }
    .onChange(of: dropTargeting) { isTargeted in
        if isTargeted, vm.status == .closed {
            vm.notchOpen(.drag)
            vm.hapticSender.send()
        } else if !isTargeted {
            let p = NSEvent.mouseLocation
            if !vm.notchOpenedRect.insetBy(dx: vm.inset, dy: vm.inset).contains(p) {
                vm.notchClose()
            }
        }
    }
```

注意：

- `Color.opacity(0.001)` 是命中测试能通过的最小 alpha。`0` 会被跳过
- 真正的文件接收应该放在面板内部的子视图里（如 tray），而不是 drop detector

---

## 9. 持久化

小配置量时不必 Core Data 也不必 UserDefaults，直接把每个 key 存成一个 JSON 文件即可。好处是配置目录可手工检查、可 sync 到 iCloud Drive、可直接备份。

核心 property wrapper：

```swift
@propertyWrapper
struct Persist<Value: Codable> {
    private let subject: CurrentValueSubject<Value, Never>
    var projectedValue: AnyPublisher<Value, Never> { subject.eraseToAnyPublisher() }

    init(key: String, defaultValue: Value, engine: PersistProvider) {
        if let data = engine.data(forKey: key),
           let object = try? JSONDecoder().decode(Value.self, from: data) {
            subject = .init(object)
        } else {
            subject = .init(defaultValue)
        }
        // 落盘订阅
        var bag: Set<AnyCancellable> = []
        subject
            .receive(on: DispatchQueue.global())
            .map { try? JSONEncoder().encode($0) }
            .removeDuplicates()
            .sink { engine.set($0, forKey: key) }
            .store(in: &bag)
        self.cancellables = bag
    }
    var wrappedValue: Value {
        get { subject.value }
        set { subject.send(newValue) }
    }
}
```

与 `@Published` 组合时，用 `static subscript(_enclosingInstance:...)` 的形式让 `objectWillChange` 发布：

```swift
@propertyWrapper
struct PublishedPersist<Value: Codable> {
    @Persist private var value: Value
    var projectedValue: AnyPublisher<Value, Never> { $value }
    static subscript<O: ObservableObject>(
        _enclosingInstance object: O,
        wrapped: ReferenceWritableKeyPath<O, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<O, PublishedPersist<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].value }
        set {
            (object.objectWillChange as? ObservableObjectPublisher)?.send()
            object[keyPath: storageKeyPath].value = newValue
        }
    }
}
```

用法：

```swift
@PublishedPersist(key: "hapticFeedback", defaultValue: true)
var hapticFeedback: Bool
```

---

## 10. 权限与 entitlements

- 仅想做展示 + 拖拽：几乎不需要额外 entitlements。`.entitlements` 保持 App Sandbox off 或默认
- 想接收任意位置文件：需要 `com.apple.security.files.user-selected.read-write`（或关闭沙盒）
- 想监听全局鼠标事件：需要「辅助功能」权限（`AXIsProcessTrusted()` 校验）
- 想截图：需要「屏幕录制」权限（`CGPreflightScreenCaptureAccess()` 校验）

权限缺失时不要 silent fail——用 `NSAlert` 或面板内一行红字告知，并给 System Settings 的深链。

---

## 11. 文件组织建议

```
App/
  main.swift                      # 入口、pidfile、self-monitor
  AppDelegate.swift               # activation policy、screen 监听、单实例轮询

Notch/
  NotchWindow.swift               # NSWindow 子类
  NotchWindowController.swift     # 定位 + 销毁
  NotchViewController.swift       # NSHostingController 包装
  NotchViewModel.swift            # 状态机 + 派生几何
  NotchViewModel+Events.swift     # 订阅组装
  NotchView.swift                 # 外壳：刘海形状 + 面板切换
  NotchContentView.swift          # 面板内部（按 contentType 路由）
  ...各业务子 view...

Input/
  EventMonitor.swift              # global + local 封装
  EventMonitors.swift             # 单例：事件源汇总

Platform/
  Ext+NSScreen.swift              # notchSize / buildin
  PublishedPersist.swift          # 持久化 property wrapper
```

---

## 12. 常见坑位 checklist

- [ ] 切换 Space / 进全屏 app → 面板仍可见（collectionBehavior 四项齐全）
- [ ] 外接显示器插拔 → 面板回到内建屏幕（订阅 `didChangeScreenParameters`）
- [ ] 菜单栏管理器（Bartender / iStat）不遮挡 → `level = .statusBar + n`
- [ ] 多桌面切回来 → 面板不闪（`.stationary`）
- [ ] App 在后台时热区 hover 仍响应 → 用 `addGlobalMonitorForEvents`
- [ ] App 在前台（已是 key window）时热区 hover 仍响应 → 同时用 `addLocalMonitorForEvents`
- [ ] 开发期二进制替换 → 旧进程自杀（pidfile + self delete monitor）
- [ ] 无刘海机型调试 → 虚拟 150×28 刘海 fallback
- [ ] 销毁 window 时 → destroy view model + 取消 cancellables + nil out controller
- [ ] Drop 检测层透明 → `opacity(0.001)` 而非 `0`
- [ ] 面板 closed 后残影 → `debounce 0.5s` 再 `notchVisible = false`
- [ ] 动画统一 → 全局一份 `Animation` 常量
- [ ] Haptic 过于频繁 → `throttle(for: .seconds(0.5))`
