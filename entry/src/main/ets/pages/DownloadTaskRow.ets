import { TaskSnapshot, TaskState } from '../webvideo/Index';

@Component
export struct DownloadTaskRow {
  // ForEach keeps the row by id; a new manager snapshot must still update its contents.
  @Prop task: TaskSnapshot;
  onPause: (id: string) => void = () => {};
  onResume: (id: string) => void = () => {};
  onCancel: (id: string) => void = () => {};
  onPlay: (path: string) => void = () => {};
  onRemove: (task: TaskSnapshot) => void = () => {};

  build() {
    Column({ space: 4 }) {
      Text(`${this.task.title} · ${this.task.state}`).maxLines(1)
      Text(this.task.message || (this.task.result ? `已保存：${this.task.result.path}` :
        `${(this.task.received / 1048576).toFixed(1)} MB${this.task.total > 0 ? ` / ${(this.task.total / 1048576).toFixed(1)} MB` : ''}`))
        .fontSize(12).maxLines(2)
      Row({ space: 8 }) {
        if (this.task.state === TaskState.Downloading || this.task.state === TaskState.Preparing) {
          Button('暂停').onClick(() => this.onPause(this.task.id))
        }
        if (this.task.state === TaskState.Paused) {
          Button('恢复').onClick(() => this.onResume(this.task.id))
        }
        if (this.task.state !== TaskState.Completed && this.task.state !== TaskState.Cancelled && this.task.state !== TaskState.Failed) {
          Button('取消').onClick(() => this.onCancel(this.task.id))
        }
        if (this.task.result) {
          Button('播放').onClick(() => { if (this.task.result) this.onPlay(this.task.result.path); })
        }
        Button('删除').onClick(() => this.onRemove(this.task))
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }
}
