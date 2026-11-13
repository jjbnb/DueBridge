using System.Diagnostics;
using System.Windows;
using DueBridge.Outlook;
namespace DueBridge.Windows;
public partial class MainWindow
{
    private sealed class TodoSetupException(string message) : Exception(message);
    private bool CanWriteTodo => _storageAvailable && !_settings.Paused && !_todoNeedsLogin && !_todoListMissing && _settings.TodoList is not null;
    private async void OnTodoLogin(object sender,RoutedEventArgs e) => await ConnectTodo(_settings.TodoAccount);
    private async void OnTodoSwitch(object sender,RoutedEventArgs e) => await ConnectTodo(null);
    private async Task ConnectTodo(OutlookAccount? expected)
    {
        await ChangeAsync("请在浏览器确认 Microsoft To Do 待办权限…",async token =>
        {
            OutlookAccount account;
            try { account=expected is null?await _todoSignIn.ConnectAsync(token):await _todoSignIn.ConnectAsync(expected,token); }
            catch(OutlookException error)
            {
                if(error.Failure==OutlookFailure.Configuration) throw new TodoSetupException("此版本尚未配置微软应用 ID。");
                throw new TodoException(error.Failure==OutlookFailure.PermissionDenied?TodoFailure.PermissionDenied:TodoFailure.SignInRequired);
            }
            token.ThrowIfCancellationRequested();
            if(_settings.TodoAccount?.HomeAccountId!=account.HomeAccountId)
                Save(_settings.ClearTodoConsent() with {TodoAccount=account,TodoList=null});
            else Save(_settings with {TodoAccount=account,TodoList=_settings.TodoList is {} list?list with {Account=account}:null});
            _todoNeedsLogin=false;_todoListMissing=false;ResetSchedule();
            Status.Text="To Do 已授权，请设置归期列表，再启用所需来源。";
        });
    }
    private async void OnTodoList(object sender,RoutedEventArgs e)
    {
        if(_settings.TodoAccount is not {} account) return;
        await ChangeAsync("正在创建或恢复归期 To Do 列表…",async token =>
        {
            var target=await _todo.CreateListAsync(account,token);token.ThrowIfCancellationRequested();
            Save(_settings.TodoList==target ? _settings : _settings.ClearTodoConsent() with {TodoList=target});_todoListMissing=false;ResetSchedule();
            Status.Text="归期 To Do 列表已设置，请按来源启用写入。";
        });
    }
    private async void OnTodoConsent(object sender,RoutedEventArgs e)
    {
        var source=CurrentSource;var binding=_settings.Source(source);
        await ChangeAsync("正在保存 To Do 同步设置…",token=>
        {
            token.ThrowIfCancellationRequested();
            Save(_settings.WithSource(source,_settings.Source(source) with {TodoEnabled=!binding.TodoEnabled}));
            _todoSchedule[source].Reset();Status.Text=binding.TodoEnabled?"已停用此来源的 To Do 同步。":"已启用此来源的 To Do 同步。";
            return Task.CompletedTask;
        });
        if(!binding.TodoEnabled) await SynchronizeAsync(automatic:false,only:source);
    }
    private void OnOpenTodo(object sender,RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("https://to-do.office.com/tasks/"){UseShellExecute=true})?.Dispose(); }
        catch(Exception error) when(error is System.ComponentModel.Win32Exception or InvalidOperationException)
        { Status.Text="请在浏览器打开 https://to-do.office.com/tasks/"; }
    }
    private async void OnTodoPending(object sender,RoutedEventArgs e)
    {
        if(_settings.TodoAccount is not {} account) return;
        var prefix=TodoTasks.PendingPrefix(account);
        var items=_settings.TodoPending.Where(p=>p.Key.StartsWith(prefix,StringComparison.Ordinal)).ToArray();
        if(items.Length==0) return;
        var result=MessageBox.Show(this,"以下创建请求结果未确认：\n"+string.Join("\n",items.Select(p=>p.Value).Take(8))+
            "\n\n请先在 To Do 检查。仅确认这些项目没有创建成功时选择“是”，允许下一次同步重新创建；若已存在，请选择“否”并重试同步以恢复标记。", "核对待确认的 To Do 创建",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No);
        if(result!=MessageBoxResult.Yes) return;
        await ChangeAsync("正在解除待确认记录…",token=>
        {
            token.ThrowIfCancellationRequested();var pending=new Dictionary<string,string>(_settings.TodoPending);
            foreach(var item in items) pending.Remove(item.Key);
            Save(_settings with {TodoPending=pending});ResetSchedule();Status.Text="已解除所选待确认记录，请点击立即更新重新检查。";
            return Task.CompletedTask;
        });
    }
    private void RenderTodoControls(bool idle,bool canInterrupt)
    {
        var binding=_settings.Source(CurrentSource);
        TodoLoginButton.IsEnabled=canInterrupt;
        TodoSwitchButton.Visibility=_settings.TodoAccount is null?Visibility.Collapsed:Visibility.Visible;
        TodoSwitchButton.IsEnabled=canInterrupt;
        TodoListButton.IsEnabled=idle&&!_todoNeedsLogin&&_settings.TodoAccount is not null;
        TodoConsentButton.Content=binding.TodoEnabled?"停用此来源到 To Do":"启用此来源到 To Do";
        TodoConsentButton.IsEnabled=binding.TodoEnabled?canInterrupt:idle&&_settings.TodoList is not null&&!_todoNeedsLogin&&!_todoListMissing&&
            !_needsSchoolLogin.Contains(CurrentSource)&&_previews.TryGetValue(CurrentSource,out var preview)&&preview.AccountId==binding.AccountId;
        TodoPendingButton.Visibility=_settings.TodoAccount is {} account&&_settings.TodoPending.Keys.Any(k=>k.StartsWith(TodoTasks.PendingPrefix(account),StringComparison.Ordinal))?Visibility.Visible:Visibility.Collapsed;
        TodoPendingButton.IsEnabled=idle;
        TodoStatus.Text=(_settings.TodoAccount?.Username??"尚未授权个人 Microsoft 账户")+
            (_todoNeedsLogin?" · 请重新授权":"")+(_settings.TodoList is null?" · 尚未设置列表":_todoListMissing?" · 列表失效":" · 已绑定归期列表")+
            (binding.TodoEnabled?"\n此来源已启用":"\n此来源未启用")+
            (binding.LastTodoSuccess is {} time?" · 上次成功 "+DisplayTime(time):" · 尚无成功记录");
    }
}
