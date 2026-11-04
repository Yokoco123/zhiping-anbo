// 智屏安播 控制台：用按钮代替串口助手发指令（启事 / 照片 / 应急 / 通知 / 字幕 / 开关 / 装字库）
// 编译：双击 build_panel.bat（用 Windows 自带的 .NET Framework 编译器，生成 智屏安播控制台.exe，不用安装任何东西）
// 指令格式和串口助手完全一样：口令 空格 指令，UTF-8，结尾回车换行；921600 bps，8-1-无校验
// 照片 / 字库：先发指令，等板子回复 READY，再连续发送文件（不用串口助手分包，约 10 秒）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing;
using System.IO;
using System.IO.Ports;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public class PanelForm : Form
{
    const int BAUD = 921600;
    static readonly Font F10 = new Font("Microsoft YaHei UI", 10f);
    static readonly Font F11 = new Font("Microsoft YaHei UI", 11f);
    static readonly Font F12 = new Font("Microsoft YaHei UI", 12f);
    static readonly Font F14B = new Font("Microsoft YaHei UI", 14f, FontStyle.Bold);
    static readonly Color C_PERSON = Color.FromArgb(0xD8, 0x43, 0x15);
    static readonly Color C_THING  = Color.FromArgb(0x15, 0x65, 0xC0);
    static readonly Color C_FOUND  = Color.FromArgb(0x2E, 0x7D, 0x32);
    static readonly Color C_L1 = Color.FromArgb(0xC6, 0x28, 0x28);
    static readonly Color C_L2 = Color.FromArgb(0xEF, 0x6C, 0x00);
    static readonly Color C_L3 = Color.FromArgb(0xFF, 0xB3, 0x00);
    static readonly Color C_OK = Color.FromArgb(0x2E, 0x7D, 0x32);
    static readonly Color C_GRAY = Color.FromArgb(0x61, 0x61, 0x61);

    readonly string baseDir;
    SerialPort port;
    ComboBox cbPort; Button btnConnect; TextBox tbPin; Label lbStatus;
    RichTextBox log; ProgressBar prog; Label lbProg;
    System.Windows.Forms.Timer timer;
    readonly List<byte> rx = new List<byte>();

    // 启事
    RadioButton rbPerson, rbThing, rbFound; TextBox tbNotice; Label lbCount; Button btnPublish;
    ComboBox cbDel, cbPhoto; CheckBox ckCrop; PictureBox pbPhoto;
    // 应急
    ComboBox cbType; TextBox tbAlarm;
    // 日常
    TextBox tbNtc, tbSub; ComboBox cbSub;
    // 系统
    TextBox tbRaw; CheckBox ckPin;

    // 发文件：0 空闲 1 等 READY 2 发送中 3 等结果
    int fState; byte[] fData; int fSent; string fName; DateTime fT0; int fWait;

    public PanelForm()
    {
        baseDir = AppDomain.CurrentDomain.BaseDirectory;
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96f, 96f);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "智屏安播 控制台 —— 社区分级信息发布终端";
        Font = F10;
        ClientSize = new Size(1000, 730);
        MinimumSize = new Size(1016, 600);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(0xF5, 0xF5, 0xF5);

        // ---------------- 顶部：串口 ----------------
        Controls.Add(Lbl("串口", 10, 16, 45));
        cbPort = new ComboBox { Location = new Point(55, 12), Size = new Size(300, 28), DropDownStyle = ComboBoxStyle.DropDownList };
        Controls.Add(cbPort);
        Controls.Add(Btn("刷新", 362, 10, 64, 32, SystemColors.Control, Color.Black, delegate { ListPorts(null); }));
        btnConnect = Btn("连接", 432, 8, 100, 36, C_OK, Color.White, delegate { ToggleConnect(); });
        Controls.Add(btnConnect);
        Controls.Add(Lbl("口令", 548, 16, 40));
        tbPin = new TextBox { Location = new Point(590, 12), Size = new Size(80, 28), Text = "8848" };
        Controls.Add(tbPin);
        lbStatus = Lbl("未连接", 685, 16, 300); lbStatus.ForeColor = C_GRAY;
        Controls.Add(lbStatus);

        // ---------------- 中间：选项卡 ----------------
        TabControl tabs = new TabControl { Location = new Point(10, 54), Size = new Size(980, 410), Font = F11, Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
        tabs.TabPages.Add(PageNotice());
        tabs.TabPages.Add(PageAlarm());
        tabs.TabPages.Add(PageDaily());
        tabs.TabPages.Add(PageSystem());
        Controls.Add(tabs);

        // ---------------- 底部：收发记录、进度 ----------------
        Controls.Add(Lbl("收发记录（→ 发出的指令，← 板子的回复）", 10, 472, 500));
        Button bc = Btn("清空", 920, 468, 70, 28, SystemColors.Control, Color.Black, delegate { log.Clear(); });
        bc.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        Controls.Add(bc);
        log = new RichTextBox { Location = new Point(10, 500), Size = new Size(980, 190), ReadOnly = true, BackColor = Color.White, Font = F10,
                                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right };
        Controls.Add(log);
        prog = new ProgressBar { Minimum = 0, Maximum = 1000, Location = new Point(10, 698), Size = new Size(760, 22), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right };
        Controls.Add(prog);
        lbProg = Lbl("", 780, 700, 210); lbProg.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        Controls.Add(lbProg);

        ResumeLayout(false);

        timer = new System.Windows.Forms.Timer { Interval = 20 };
        timer.Tick += delegate { Poll(); };
        timer.Start();
        FormClosing += delegate { SaveSettings(); ClosePort(); };

        string savedPort = LoadSettings();
        ListPorts(savedPort);
        Note("使用方法：插上板子的 USB 串口线 → 选 CH340 那个串口 → 点“连接” → 在上面的选项卡里点按钮。指令和回复都显示在这里。");
    }

    // ======================= 选项卡 =======================
    TabPage PageNotice()
    {
        TabPage p = new TabPage("  启事  ");
        rbPerson = TypeBtn("寻人启事", 10, C_PERSON);
        rbThing  = TypeBtn("寻物启事", 170, C_THING);
        rbFound  = TypeBtn("失物招领", 330, C_FOUND);
        rbPerson.Checked = true;
        p.Controls.Add(rbPerson); p.Controls.Add(rbThing); p.Controls.Add(rbFound);
        p.Controls.Add(Btn("填入示例", 500, 14, 110, 36, SystemColors.Control, Color.Black, delegate { FillSample(); }));

        tbNotice = new TextBox { Location = new Point(10, 64), Size = new Size(600, 150), Multiline = true, Font = F12, ScrollBars = ScrollBars.Vertical };
        tbNotice.TextChanged += delegate { UpdateCount(); };
        p.Controls.Add(tbNotice);
        lbCount = Lbl("", 10, 220, 600); lbCount.ForeColor = C_GRAY; lbCount.Font = F10;
        p.Controls.Add(lbCount);
        btnPublish = Btn("发布寻人启事（立即插播）", 10, 250, 600, 60, C_PERSON, Color.White, delegate { Publish(); });
        btnPublish.Font = F14B;
        p.Controls.Add(btnPublish);
        UpdateCount();
        OnTypeChanged();

        GroupBox gm = Grp("管理启事（最多 4 条，断电不丢）", 630, 6, 330, 118);
        gm.Controls.Add(Btn("查看现有启事", 10, 28, 150, 34, SystemColors.Control, Color.Black, delegate { Send("启事"); }));
        gm.Controls.Add(Btn("撤销全部", 170, 28, 150, 34, SystemColors.Control, Color.Black, delegate {
            if (Ask("确定撤销全部启事？")) Send("撤销全部"); }));
        gm.Controls.Add(Lbl("撤销第", 10, 78, 56));
        cbDel = Num(66, 74); gm.Controls.Add(cbDel);
        gm.Controls.Add(Lbl("条", 128, 78, 30));
        gm.Controls.Add(Btn("撤销", 170, 70, 150, 34, SystemColors.Control, Color.Black, delegate { Send("撤销" + cbDel.Text); }));
        p.Controls.Add(gm);

        GroupBox gp = Grp("启事照片（先发布启事，再给它加照片）", 630, 130, 330, 236);
        gp.Controls.Add(Lbl("给第", 10, 32, 40));
        cbPhoto = Num(50, 28); gp.Controls.Add(cbPhoto);
        gp.Controls.Add(Lbl("条启事加照片", 112, 32, 120));
        gp.Controls.Add(Btn("选择照片并发送…", 10, 66, 200, 40, C_THING, Color.White, delegate { PickPhoto(); }));
        ckCrop = new CheckBox { Text = "裁切铺满（不留白边）", Location = new Point(10, 112), Size = new Size(310, 26), Font = F10 };
        gp.Controls.Add(ckCrop);
        gp.Controls.Add(Btn("发送现有 PHOTO.BIN", 10, 144, 200, 34, SystemColors.Control, Color.Black, delegate { SendPhotoBin(); }));
        pbPhoto = new PictureBox { Location = new Point(218, 66), Size = new Size(100, 89), SizeMode = PictureBoxSizeMode.Zoom, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White };
        gp.Controls.Add(pbPhoto);
        Label lh = Lbl("照片在电脑上转成 PHOTO.BIN，约 10 秒传完；屏上显示的效果见右边预览", 10, 186, 310); lh.Height = 44; lh.ForeColor = C_GRAY; lh.Font = F10;
        gp.Controls.Add(lh);
        p.Controls.Add(gp);
        ShowPreview();
        return p;
    }

    TabPage PageAlarm()
    {
        TabPage p = new TabPage("  应急  ");
        p.Controls.Add(Lbl("类型", 10, 18, 44));
        cbType = new ComboBox { Location = new Point(56, 14), Size = new Size(120, 30), DropDownStyle = ComboBoxStyle.DropDownList };
        cbType.Items.AddRange(new object[] { "不指定", "火灾", "地震", "治安", "故障" });
        cbType.SelectedIndex = 0;
        p.Controls.Add(cbType);
        p.Controls.Add(Lbl("内容（可不填，不填就显示这一类 / 这一级的提示语）", 196, 18, 420));
        tbAlarm = new TextBox { Location = new Point(10, 52), Size = new Size(950, 30), Font = F12 };
        p.Controls.Add(tbAlarm);

        Button b1 = Btn("一级  紧急撤离\n疏散图 · 连续警笛 · 停止节目", 10, 96, 310, 96, C_L1, Color.White, delegate { Alarm(1); });
        Button b2 = Btn("二级  就地避险\n橙色提示页 · 间歇音 · 停止节目", 330, 96, 310, 96, C_L2, Color.White, delegate { Alarm(2); });
        Button b3 = Btn("三级  区域警戒\n边框 + 标签 · 响一次 · 节目照常", 650, 96, 310, 96, C_L3, Color.Black, delegate { Alarm(3); });
        b1.Font = F14B; b2.Font = F14B; b3.Font = F14B;
        p.Controls.Add(b1); p.Controls.Add(b2); p.Controls.Add(b3);

        Button bm = Btn("消音（画面告警保持）", 10, 206, 310, 60, C_GRAY, Color.White, delegate { Send("消音"); });
        Button bx = Btn("解除应急，恢复正常播放", 330, 206, 630, 60, C_OK, Color.White, delegate { Send("解除"); });
        bm.Font = F12; bx.Font = F14B;
        p.Controls.Add(bm); p.Controls.Add(bx);

        Label h = Lbl("设备不判断灾情，只执行管理员选的等级和类型。按键 Key4 长按、干接点（J1 第 10 脚接地）也能直接进入一级。\n" +
                      "示例：类型“火灾”+ 一级；类型“地震”+ 二级；内容“东门临时封闭，请走西门”+ 三级。", 10, 280, 950);
        h.Height = 60; h.ForeColor = C_GRAY; h.Font = F10;
        p.Controls.Add(h);
        return p;
    }

    TabPage PageDaily()
    {
        TabPage p = new TabPage("  日常  ");
        GroupBox gn = Grp("通知（屏幕底部黄色滚动条）", 10, 6, 470, 120);
        tbNtc = new TextBox { Location = new Point(10, 30), Size = new Size(450, 30), Font = F12, Text = "今晚8点至10点小区停水检修，请提前储水" };
        gn.Controls.Add(tbNtc);
        gn.Controls.Add(Btn("发送通知", 10, 72, 140, 36, C_THING, Color.White, delegate { SendText("通知", tbNtc.Text, "通知内容"); }));
        gn.Controls.Add(Btn("撤销通知", 160, 72, 140, 36, SystemColors.Control, Color.Black, delegate { Send("撤销通知"); }));
        p.Controls.Add(gn);

        GroupBox gs = Grp("图片字幕（每张图下面那条，断电不丢）", 10, 134, 470, 160);
        gs.Controls.Add(Lbl("第", 10, 32, 24));
        cbSub = Num(34, 28); gs.Controls.Add(cbSub);
        gs.Controls.Add(Lbl("张图（PIC1～PIC4）", 96, 32, 200));
        tbSub = new TextBox { Location = new Point(10, 66), Size = new Size(450, 30), Font = F12, Text = "本周六上午9点社区广场义诊，欢迎居民参加" };
        gs.Controls.Add(tbSub);
        gs.Controls.Add(Btn("设置字幕", 10, 108, 140, 36, C_THING, Color.White, delegate { SendText("字幕" + cbSub.Text, tbSub.Text, "字幕内容"); }));
        gs.Controls.Add(Btn("恢复默认字幕", 160, 108, 160, 36, SystemColors.Control, Color.Black, delegate { Send("字幕" + cbSub.Text); }));
        p.Controls.Add(gs);

        GroupBox gw = Grp("开关", 495, 6, 465, 330);
        string[] names = { "字幕", "波形", "分辨率", "轮播", "音乐" };
        string[] notes = { "", "", "左上角原图分辨率", "", "背景音乐" };
        for (int i = 0; i < names.Length; i++)
        {
            int y = 28 + i * 44;
            string n = names[i];
            gw.Controls.Add(Lbl(n, 12, y + 7, 70));
            gw.Controls.Add(Btn("开", 90, y, 100, 36, C_OK, Color.White, delegate { Send(n + "开"); }));
            gw.Controls.Add(Btn("关", 200, y, 100, 36, C_GRAY, Color.White, delegate { Send(n + "关"); }));
            Label ln = Lbl(notes[i], 310, y + 8, 150); ln.ForeColor = C_GRAY; ln.Font = F10;
            gw.Controls.Add(ln);
        }
        gw.Controls.Add(Lbl("翻页", 12, 28 + 5 * 44 + 7, 70));
        gw.Controls.Add(Btn("上一张", 90, 28 + 5 * 44, 100, 36, SystemColors.Control, Color.Black, delegate { Send("上一张"); }));
        gw.Controls.Add(Btn("下一张", 200, 28 + 5 * 44, 100, 36, SystemColors.Control, Color.Black, delegate { Send("下一张"); }));
        p.Controls.Add(gw);
        return p;
    }

    TabPage PageSystem()
    {
        TabPage p = new TabPage("  系统  ");
        p.Controls.Add(Btn("查看全部指令（帮助）", 10, 14, 220, 40, SystemColors.Control, Color.Black, delegate { Send("帮助"); }));
        p.Controls.Add(Btn("装字库（FONT.BIN）…", 240, 14, 220, 40, C_THING, Color.White, delegate { InstallFont(); }));
        Label hf = Lbl("字库只需装一次（存在板子的 Flash 里）。FONT.BIN 由 gen_font.bat 生成，和本程序放在同一个文件夹会自动找到；约 8 秒传完。", 10, 62, 950);
        hf.ForeColor = C_GRAY; hf.Font = F10; hf.Height = 44;
        p.Controls.Add(hf);

        GroupBox gr = Grp("自己输入指令（和串口助手一样）", 10, 116, 950, 110);
        tbRaw = new TextBox { Location = new Point(10, 32), Size = new Size(760, 30), Font = F12, Text = "帮助" };
        tbRaw.KeyDown += delegate (object s, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; SendRaw(); } };
        gr.Controls.Add(tbRaw);
        gr.Controls.Add(Btn("发送", 780, 28, 150, 38, C_THING, Color.White, delegate { SendRaw(); }));
        ckPin = new CheckBox { Text = "自动在前面加口令", Checked = true, Location = new Point(10, 72), Size = new Size(300, 26), Font = F10 };
        gr.Controls.Add(ckPin);
        p.Controls.Add(gr);

        Label h = Lbl("串口参数：921600 bps，8 位数据，1 位停止，无校验，UTF-8。本程序和串口助手不能同时连接同一个串口。", 10, 240, 950);
        h.ForeColor = C_GRAY; h.Font = F10;
        p.Controls.Add(h);
        return p;
    }

    // ======================= 动作 =======================
    string NoticeKw() { return rbPerson.Checked ? "寻人" : rbThing.Checked ? "寻物" : "招领"; }
    Color NoticeColor() { return rbPerson.Checked ? C_PERSON : rbThing.Checked ? C_THING : C_FOUND; }

    void OnTypeChanged()
    {
        if (btnPublish == null) return;
        btnPublish.BackColor = NoticeColor();
        btnPublish.Text = "发布" + (rbPerson.Checked ? "寻人启事" : rbThing.Checked ? "寻物启事" : "失物招领") + "（立即插播）";
        foreach (RadioButton r in new RadioButton[] { rbPerson, rbThing, rbFound })
        {
            Color c = (Color)r.Tag;
            r.BackColor = r.Checked ? c : Color.White;
            r.ForeColor = r.Checked ? Color.White : c;
        }
    }

    void FillSample()
    {
        if (rbPerson.Checked)
            tbNotice.Text = "张大爷，78岁，身高约170厘米，穿蓝色外套，今早在小区东门走失，有轻微记忆障碍，见到请联系社区服务中心";
        else if (rbThing.Checked)
            tbNotice.Text = "本人于11月1日下午在社区服务中心一楼大厅遗失黑色双肩包一个，内有笔记本电脑一台、身份证、银行卡、钥匙一串和蓝色保温杯，电脑里有重要工作资料，请拾到者联系社区服务中心或拨打电话01234567896，必有酬谢，非常感谢！";
        else
            tbNotice.Text = "今天上午在3号楼电梯口拾到钥匙一串（带红色挂绳），请失主到社区服务中心认领";
    }

    static double Width2(string s)
    {
        double w = 0;
        foreach (char c in s) { if (c == '\r' || c == '\n') continue; w += c < 0x80 ? 0.5 : 1.0; }
        return w;
    }

    void UpdateCount()
    {
        double w = Width2(tbNotice.Text);
        string tip = w <= 72 ? "大字显示" : w <= 127 ? "字多，自动换小字" : "太长，屏上只显示前面约 127 字";
        lbCount.Text = string.Format("约 {0} 字 —— {1}（大字约 72 字以内，小字最多约 127 字；带照片时右边文字区更窄）", Math.Ceiling(w), tip);
        lbCount.ForeColor = w > 127 ? C_L1 : C_GRAY;
    }

    void Publish()
    {
        SendText(NoticeKw(), tbNotice.Text, "启事内容");
    }

    void Alarm(int lv)
    {
        string body = "应急" + lv;
        if (cbType.SelectedIndex > 0) body += " " + cbType.Text;
        string t = OneLine(tbAlarm.Text);
        if (t != "") body += " " + t;
        Send(body);
    }

    void SendText(string kw, string text, string what)
    {
        string t = OneLine(text);
        if (t == "") { MessageBox.Show(this, "请先填写" + what + "。", Text); return; }
        Send(kw + " " + t);
    }

    void SendRaw()
    {
        string t = OneLine(tbRaw.Text);
        if (t == "") return;
        if (ckPin.Checked) Send(t); else SendLine(t);
    }

    static string OneLine(string s)
    {
        return s.Replace("\r\n", " ").Replace("\r", " ").Replace("\n", " ").Trim();
    }

    void PickPhoto()
    {
        if (!Connected()) return;
        OpenFileDialog d = new OpenFileDialog { Title = "选择启事照片", Filter = "照片|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|PHOTO.BIN|*.bin|全部文件|*.*" };
        if (d.ShowDialog(this) != DialogResult.OK) return;
        string bin = Path.Combine(baseDir, "PHOTO.BIN");
        if (d.FileName.EndsWith(".bin", StringComparison.OrdinalIgnoreCase)) { bin = d.FileName; }
        else
        {
            Note("正在把照片转成 PHOTO.BIN（转正、缩放、编码）……");
            Cursor = Cursors.WaitCursor;
            Application.DoEvents();
            try
            {
                int w, h;
                byte[] file;
                using (Bitmap b = PhotoGen.Prepare(d.FileName, ckCrop.Checked ? "crop" : "fit", out w, out h))
                    file = PhotoGen.Build(b);
                File.WriteAllBytes(bin, file);
                using (Bitmap pv = PhotoGen.Preview(file))
                    pv.Save(Path.Combine(baseDir, "PHOTO_preview.png"), ImageFormat.Png);
                Note(string.Format("照片 {0} × {1} → PHOTO.BIN（{2} 字节）", w, h, file.Length) + (w < 720 || h < 640 ? "，照片比 720×640 小，已放大" : ""));
            }
            catch (Exception ex)
            {
                Cursor = Cursors.Default;
                Err("照片转换失败：" + ex.Message + "（这张图读不出来？jpg / png / bmp 都可以，webp、HEIC 不行）");
                Err("照片：" + d.FileName);
                return;
            }
            Cursor = Cursors.Default;
            ShowPreview();
        }
        StartFile("照片" + cbPhoto.Text, bin, 921856, "照片", 60);
    }

    void SendPhotoBin()
    {
        if (!Connected()) return;
        string bin = Path.Combine(baseDir, "PHOTO.BIN");
        if (!File.Exists(bin)) { MessageBox.Show(this, "没有找到 PHOTO.BIN，请用“选择照片并发送…”。", Text); return; }
        ShowPreview();
        StartFile("照片" + cbPhoto.Text, bin, 921856, "照片", 60);
    }

    void InstallFont()
    {
        if (!Connected()) return;
        string f = Path.Combine(baseDir, "FONT.BIN");
        if (!File.Exists(f))
        {
            OpenFileDialog d = new OpenFileDialog { Title = "选择 FONT.BIN", Filter = "FONT.BIN|*.bin|全部文件|*.*" };
            if (d.ShowDialog(this) != DialogResult.OK) return;
            f = d.FileName;
        }
        if (!Ask("装字库会先擦除板子 Flash 里的旧字库，大约要 10 多秒，期间不要断电。继续？")) return;
        StartFile("装字库", f, 0, "字库", 90);
    }

    void ShowPreview()
    {
        string pv = Path.Combine(baseDir, "PHOTO_preview.png");
        if (pbPhoto.Image != null) { pbPhoto.Image.Dispose(); pbPhoto.Image = null; }
        if (!File.Exists(pv)) return;
        try { using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(pv))) { pbPhoto.Image = new Bitmap(ms); } }
        catch { }
    }

    // ======================= 发文件 =======================
    void StartFile(string cmd, string path, int expectLen, string what, int waitSec)
    {
        if (fState != 0) { MessageBox.Show(this, "上一个文件还没传完。", Text); return; }
        byte[] data;
        try { data = File.ReadAllBytes(path); } catch (Exception ex) { Err("读不出文件：" + ex.Message); return; }
        if (expectLen > 0 && data.Length != expectLen) { Err(string.Format("{0} 文件大小不对（{1} 字节，应该是 {2}），请重新生成", Path.GetFileName(path), data.Length, expectLen)); return; }
        fData = data; fSent = 0; fName = what; fWait = waitSec; fT0 = DateTime.Now; fState = 1;
        prog.Value = 0; lbProg.Text = "等板子准备（擦除 Flash）……";
        Send(cmd);
    }

    void FileTick()
    {
        if (fState == 1 && (DateTime.Now - fT0).TotalSeconds > fWait) { FileEnd(false, "等了 " + fWait + " 秒没收到 READY"); return; }
        if (fState == 2)
        {
            try
            {
                while (fSent < fData.Length && port.BytesToWrite < 16384)
                {
                    int n = Math.Min(4096, fData.Length - fSent);
                    port.Write(fData, fSent, n);
                    fSent += n;
                }
            }
            catch (Exception ex) { FileEnd(false, "发送出错：" + ex.Message); return; }
            int done = fSent - port.BytesToWrite;
            if (done < 0) done = 0;
            prog.Value = Math.Max(0, Math.Min(1000, (int)(1000L * done / fData.Length)));
            lbProg.Text = string.Format("发送{0}：{1}%  {2:F0} 秒", fName, 100L * done / fData.Length, (DateTime.Now - fT0).TotalSeconds);
            if (fSent >= fData.Length && port.BytesToWrite == 0) { fState = 3; fT0 = DateTime.Now; lbProg.Text = "已发完，等板子校验……"; }
        }
        if (fState == 3 && (DateTime.Now - fT0).TotalSeconds > 60) FileEnd(false, "发完后 60 秒没收到结果");
    }

    void FileLine(string line)
    {
        if (fState == 1 && line.StartsWith("READY")) { fState = 2; fSent = 0; fT0 = DateTime.Now; return; }
        if (fState == 1 && line.StartsWith("ERR")) { FileEnd(false, null); return; }
        if (fState == 3 && line.StartsWith("OK")) { FileEnd(true, null); return; }
        if (fState == 3 && line.StartsWith("ERR")) { FileEnd(false, null); return; }
    }

    void FileEnd(bool ok, string msg)
    {
        fState = 0; fData = null;
        prog.Value = ok ? 1000 : 0;
        lbProg.Text = ok ? fName + "发送完成" : fName + "没有发成功";
        if (msg != null) Err(msg);
    }

    // ======================= 串口 =======================
    void ListPorts(string prefer)
    {
        string cur = prefer ?? (cbPort.SelectedItem as PortItem != null ? ((PortItem)cbPort.SelectedItem).Name : null);
        cbPort.Items.Clear();
        Dictionary<string, string> desc = new Dictionary<string, string>();
        try
        {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT Name FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'"))
                foreach (ManagementObject o in s.Get())
                {
                    string n = Convert.ToString(o["Name"]);
                    int a = n.LastIndexOf("(COM");
                    int b = n.IndexOf(')', a);
                    if (a >= 0 && b > a) desc[n.Substring(a + 1, b - a - 1)] = n.Substring(0, a).Trim();
                }
        }
        catch { }
        int pick = -1;
        foreach (string n in SerialPort.GetPortNames())
        {
            string d;
            desc.TryGetValue(n, out d);
            PortItem it = new PortItem { Name = n, Desc = d ?? "" };
            int i = cbPort.Items.Add(it);
            if (cur != null && n == cur) pick = i;
            else if (pick < 0 && it.Desc.ToUpper().Contains("CH34")) pick = i;
        }
        if (cbPort.Items.Count == 0) { lbStatus.Text = "没有找到串口：插上板子的 USB 串口线后点“刷新”"; lbStatus.ForeColor = C_L1; return; }
        cbPort.SelectedIndex = pick >= 0 ? pick : 0;
        if (port == null || !port.IsOpen) { lbStatus.Text = "未连接"; lbStatus.ForeColor = C_GRAY; }
    }

    class PortItem
    {
        public string Name, Desc;
        public override string ToString() { return Desc == "" ? Name : Name + "  " + Desc; }
    }

    void ToggleConnect()
    {
        if (port != null && port.IsOpen) { ClosePort(); return; }
        PortItem it = cbPort.SelectedItem as PortItem;
        if (it == null) { MessageBox.Show(this, "没有可用的串口。", Text); return; }
        try
        {
            port = new SerialPort(it.Name, BAUD, Parity.None, 8, StopBits.One);
            port.Handshake = Handshake.None;
            port.WriteBufferSize = 65536;
            port.ReadBufferSize = 65536;
            port.WriteTimeout = 5000;
            port.Open();
        }
        catch (Exception ex)
        {
            port = null;
            Err("打不开 " + it.Name + "：" + ex.Message + "（串口助手是不是还连着？）");
            return;
        }
        btnConnect.Text = "断开"; btnConnect.BackColor = C_GRAY;
        lbStatus.Text = "已连接 " + it.Name + "，921600 bps"; lbStatus.ForeColor = C_OK;
        cbPort.Enabled = false;
        rx.Clear();
        Note("已连接 " + it.Name);
        SaveSettings();
    }

    void ClosePort()
    {
        if (fState != 0) FileEnd(false, "串口断开，文件没有发完");
        try { if (port != null) port.Close(); } catch { }
        port = null;
        btnConnect.Text = "连接"; btnConnect.BackColor = C_OK;
        lbStatus.Text = "未连接"; lbStatus.ForeColor = C_GRAY;
        cbPort.Enabled = true;
    }

    bool Connected()
    {
        if (port != null && port.IsOpen) return true;
        MessageBox.Show(this, "请先在上面选串口，点“连接”。", Text);
        return false;
    }

    void Send(string body)
    {
        string pin = tbPin.Text.Trim();
        SendLine(pin == "" ? body : pin + " " + body);
    }

    void SendLine(string line)
    {
        if (!Connected()) return;
        byte[] b = Encoding.UTF8.GetBytes(line + "\r\n");
        try { port.Write(b, 0, b.Length); }
        catch (Exception ex) { Err("发送失败：" + ex.Message); ClosePort(); return; }
        Append("→ " + line, Color.FromArgb(0x42, 0x42, 0x42));
    }

    void Poll()
    {
        if (port == null) return;
        try
        {
            if (!port.IsOpen) { ClosePort(); return; }
            int n = port.BytesToRead;
            if (n > 0)
            {
                byte[] b = new byte[n];
                int got = port.Read(b, 0, n);
                for (int i = 0; i < got; i++) rx.Add(b[i]);
                int k;
                while ((k = rx.IndexOf((byte)'\n')) >= 0)
                {
                    string line = Encoding.UTF8.GetString(rx.GetRange(0, k).ToArray()).TrimEnd('\r');
                    rx.RemoveRange(0, k + 1);
                    if (line.Length == 0) continue;
                    Color c = line.StartsWith("OK") ? C_OK : line.StartsWith("ERR") ? C_L1 : line.StartsWith("READY") ? C_THING : Color.Black;
                    Append("← " + line, c);
                    FileLine(line);
                }
                if (rx.Count > 8192) rx.Clear();
            }
            FileTick();
        }
        catch (Exception ex)
        {
            Err("串口出错：" + ex.Message + "（USB 线是不是拔了？）");
            ClosePort();
        }
    }

    // ======================= 记录 =======================
    void Append(string s, Color c)
    {
        if (log.TextLength > 200000) log.Clear();
        log.SelectionStart = log.TextLength;
        log.SelectionLength = 0;
        log.SelectionColor = Color.FromArgb(0x9E, 0x9E, 0x9E);
        log.AppendText(DateTime.Now.ToString("HH:mm:ss  "));
        log.SelectionColor = c;
        log.AppendText(s + "\n");
        log.SelectionStart = log.TextLength;
        log.ScrollToCaret();
    }
    void Note(string s) { Append(s, C_THING); }
    void Err(string s) { Append(s, C_L1); }
    bool Ask(string q) { return MessageBox.Show(this, q, Text, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK; }

    // ======================= 设置 =======================
    string SettingsFile { get { return Path.Combine(baseDir, "panel_settings.txt"); } }
    string LoadSettings()
    {
        string p = null;
        try
        {
            foreach (string l in File.ReadAllLines(SettingsFile, Encoding.UTF8))
            {
                if (l.StartsWith("port=")) p = l.Substring(5).Trim();
                if (l.StartsWith("pin=") && l.Length > 4) tbPin.Text = l.Substring(4).Trim();
            }
        }
        catch { }
        return p;
    }
    void SaveSettings()
    {
        try
        {
            PortItem it = cbPort.SelectedItem as PortItem;
            File.WriteAllLines(SettingsFile, new string[] { "port=" + (it == null ? "" : it.Name), "pin=" + tbPin.Text.Trim() }, Encoding.UTF8);
        }
        catch { }
    }

    // ======================= 控件小工具 =======================
    static Label Lbl(string t, int x, int y, int w)
    {
        return new Label { Text = t, Location = new Point(x, y), Size = new Size(w, 24), AutoSize = false };
    }
    static Button Btn(string t, int x, int y, int w, int h, Color back, Color fore, EventHandler click)
    {
        Button b = new Button { Text = t, Location = new Point(x, y), Size = new Size(w, h), BackColor = back, ForeColor = fore, FlatStyle = FlatStyle.Flat, Cursor = Cursors.Hand };
        b.FlatAppearance.BorderColor = Color.FromArgb(0xBD, 0xBD, 0xBD);
        b.UseVisualStyleBackColor = false;
        b.Click += click;
        return b;
    }
    static GroupBox Grp(string t, int x, int y, int w, int h)
    {
        return new GroupBox { Text = t, Location = new Point(x, y), Size = new Size(w, h), Font = F10 };
    }
    static ComboBox Num(int x, int y)
    {
        ComboBox c = new ComboBox { Location = new Point(x, y), Size = new Size(56, 28), DropDownStyle = ComboBoxStyle.DropDownList };
        c.Items.AddRange(new object[] { "1", "2", "3", "4" });
        c.SelectedIndex = 0;
        return c;
    }
    RadioButton TypeBtn(string t, int x, Color c)
    {
        RadioButton r = new RadioButton { Text = t, Location = new Point(x, 10), Size = new Size(150, 44), Appearance = Appearance.Button,
                                          TextAlign = ContentAlignment.MiddleCenter, FlatStyle = FlatStyle.Flat, Font = F14B, Tag = c, Cursor = Cursors.Hand };
        r.FlatAppearance.BorderColor = c;
        r.FlatAppearance.BorderSize = 2;
        r.FlatAppearance.CheckedBackColor = c;
        r.BackColor = Color.White; r.ForeColor = c;
        r.CheckedChanged += delegate { OnTypeChanged(); };
        return r;
    }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    public static void Main()
    {
        try { if (Environment.OSVersion.Version.Major >= 6) SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new PanelForm());
    }
}

// ---------------- 照片 → PHOTO.BIN（和 gen_photo.ps1 里的完全一样，直接编进程序，不再调用 PowerShell） ----------------
public static class PhotoGen {
    public const int W = 720, H = 640, OW = 360, OH = 320;
    public static Bitmap Prepare(string path, string mode, out int srcW, out int srcH) {
        Image img = Image.FromFile(path);
        // EXIF orientation (phone photos)
        foreach (int id in img.PropertyIdList) {
            if (id != 0x0112) continue;
            int o = img.GetPropertyItem(id).Value[0];
            RotateFlipType t = RotateFlipType.RotateNoneFlipNone;
            if (o == 2) t = RotateFlipType.RotateNoneFlipX;
            else if (o == 3) t = RotateFlipType.Rotate180FlipNone;
            else if (o == 4) t = RotateFlipType.Rotate180FlipX;
            else if (o == 5) t = RotateFlipType.Rotate90FlipX;
            else if (o == 6) t = RotateFlipType.Rotate90FlipNone;
            else if (o == 7) t = RotateFlipType.Rotate270FlipX;
            else if (o == 8) t = RotateFlipType.Rotate270FlipNone;
            img.RotateFlip(t);
        }
        srcW = img.Width; srcH = img.Height;
        // source rectangle (cx, cy, cw, ch) -> destination rectangle (dx, dy, dw, dh) in the 720 x 640 frame
        int cx = 0, cy = 0, cw = srcW, ch = srcH, dx = 0, dy = 0, dw = W, dh = H;
        bool wide = (long)srcW * H > (long)srcH * W;            // wider than 3:4
        if (mode == "crop") {                                   // keep the middle
            if (wide) cw = (int)Math.Round((double)srcH * W / H); else ch = (int)Math.Round((double)srcW * H / W);
            if (cw < 1) cw = 1; if (ch < 1) ch = 1;
            cx = (srcW - cw) / 2; cy = (srcH - ch) / 2;
        } else if (mode != "stretch") {                         // fit: whole photo, bars
            if (wide) { dh = (int)Math.Round((double)W * srcH / srcW); if (dh < 1) dh = 1; dy = (H - dh) / 2; }
            else      { dw = (int)Math.Round((double)H * srcW / srcH); if (dw < 1) dw = 1; dx = (W - dw) / 2; }
        }
        Bitmap b = new Bitmap(W, H, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(b)) {
            g.Clear(Color.White);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            using (ImageAttributes ia = new ImageAttributes()) {
                ia.SetWrapMode(WrapMode.TileFlipXY);          // no dark edge when scaling
                g.DrawImage(img, new Rectangle(dx, dy, dw, dh), cx, cy, cw, ch, GraphicsUnit.Pixel, ia);
            }
        }
        img.Dispose();
        return b;
    }
    static byte[] Pixels(Bitmap b) {           // B G R per pixel, rows top to bottom, no padding
        BitmapData d = b.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        byte[] row = new byte[d.Stride];
        byte[] px = new byte[W * H * 3];
        for (int y = 0; y < H; y++) {
            Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), row, 0, d.Stride);
            Array.Copy(row, 0, px, y * W * 3, W * 3);
        }
        b.UnlockBits(d);
        return px;
    }
    public static byte[] Build(Bitmap b) {
        byte[] px = Pixels(b);
        int dataLen = W * H * 2;
        byte[] file = new byte[dataLen + 256];
        int k = 0;
        for (int oy = OH - 1; oy >= 0; oy--)
            for (int ox = 0; ox < OW; ox++)
                for (int j = 0; j < 4; j++) {
                    int x = 2 * ox + (j & 1), y = 2 * oy + (j >> 1);
                    int a = (y * W + x) * 3;
                    int r5 = (px[a + 2] * 31 + 127) / 255, g6 = (px[a + 1] * 63 + 127) / 255, b5 = (px[a] * 31 + 127) / 255;
                    int v = (r5 << 11) | (g6 << 5) | b5;
                    file[k++] = (byte)(v >> 8); file[k++] = (byte)(v & 255);
                }
        for (int i = 0; i < 256; i++) file[dataLen + i] = 0xFF;
        byte[] magic = System.Text.Encoding.ASCII.GetBytes("ZPPHOT02");
        Array.Copy(magic, 0, file, dataLen, 8);
        file[dataLen + 8] = (byte)(W >> 8); file[dataLen + 9] = (byte)(W & 255); file[dataLen + 10] = (byte)(H >> 8); file[dataLen + 11] = (byte)(H & 255);
        Put32(file, dataLen + 12, (uint)dataLen);
        Put32(file, dataLen + 16, Crc32(file, dataLen));
        return file;
    }
    static void Put32(byte[] b, int at, uint v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }
    public static uint Crc32(byte[] data, int n) {
        uint c = 0xFFFFFFFF;
        for (int k = 0; k < n; k++) {
            c ^= (uint)data[k] << 24;
            for (int i = 0; i < 8; i++) c = ((c & 0x80000000) != 0) ? (c << 1) ^ 0x04C11DB7 : (c << 1);
        }
        return c;
    }
    // what the FPGA shows: RGB565 -> 888 (top bits copied down), 2 x 2 average with rounding, from the file itself
    public static Bitmap Preview(byte[] file) {
        Bitmap p = new Bitmap(OW, OH, PixelFormat.Format24bppRgb);
        int k = 0;
        for (int oy = OH - 1; oy >= 0; oy--)
            for (int ox = 0; ox < OW; ox++) {
                int sb = 0, sg = 0, sr = 0;
                for (int j = 0; j < 4; j++) {
                    int v = (file[k] << 8) | file[k + 1]; k += 2;
                    int r5 = v >> 11, g6 = (v >> 5) & 63, b5 = v & 31;
                    sr += (r5 << 3) | (r5 >> 2); sg += (g6 << 2) | (g6 >> 4); sb += (b5 << 3) | (b5 >> 2);
                }
                p.SetPixel(ox, oy, Color.FromArgb((sr + 2) >> 2, (sg + 2) >> 2, (sb + 2) >> 2));
            }
        return p;
    }
}
