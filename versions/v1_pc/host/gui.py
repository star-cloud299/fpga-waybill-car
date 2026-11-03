"""Tkinter main-thread UI; camera and board/reference jobs communicate via a queue."""
from __future__ import annotations
import json
from pathlib import Path
from queue import Queue,Empty
import threading
import traceback
import time
import tkinter as tk
from tkinter import ttk,filedialog,messagebox
from PIL import Image,ImageOps,ImageTk
from common import ROOT,Config,DEFAULTS,prepare_roi,rgb565,dump_json
from experiment import fresh_run,load_profile,save_table
from runner import BoardSession,run_one
from roi_controls import parse_roi,standard_sample
from gui_status import completion_message
from auto_roi import auto_select_roi

MODES={1:'1 灰度',2:'2 固定阈值',3:'3 自适应3x3',4:'4 自适应15x15',5:'5 对比度偏置'}

class App:
    def __init__(self,root):
        self.root=root;root.title('快递面单条码预处理 · 正式 V2 · 实拍自动定位 v4.1');root.geometry('1160x850')
        self.queue=Queue();self.stop=threading.Event();self.camera_stop=threading.Event()
        self.camera_frame=None;self.image=None;self.roi_box=None;self.busy=False;self.close_after=False
        self.photos={};self.last_run=None;self.drag=None;self.preview_size=(1,1)
        self.roi_text=tk.StringVar();self.last_match_summary=''
        self.auto_roi_enabled=tk.BooleanVar(value=True);self.auto_roi_info=None;self.auto_error=None
        self.transport=tk.StringVar(value='offline');self.port=tk.StringVar();self.mode=tk.StringVar(value=MODES[4])
        self.expected=tk.StringVar();self.status=tk.StringVar(value='读取实拍图片即可自动定位；五模式共用同一输入。')
        self.params={k:tk.StringVar(value=str(v)) for k,v in DEFAULTS.items()}
        self.frozen=tk.BooleanVar(value=True);self.compare=tk.BooleanVar(value=True);self.cam_index=tk.StringVar(value='0')
        self.controls=[]
        toolbar=ttk.Frame(root,padding=8);toolbar.pack(fill='x')
        self.button(toolbar,'读取图片',self.open_image).pack(side='left',padx=3)
        self.button(toolbar,'载入标准示例',self.load_standard_example).pack(side='left',padx=3)
        ttk.Label(toolbar,text='摄像头序号').pack(side='left');ttk.Entry(toolbar,textvariable=self.cam_index,width=3).pack(side='left')
        self.button(toolbar,'预览摄像头',self.start_camera).pack(side='left',padx=3)
        self.button(toolbar,'拍摄并冻结',self.capture).pack(side='left',padx=3)
        self.button(toolbar,'重置ROI',self.reset_roi).pack(side='left',padx=3)
        ttk.Label(toolbar,text='画布192x96，四周保留7像素裁边余量').pack(side='left',padx=10)
        connect=ttk.Frame(root,padding=(8,0));connect.pack(fill='x')
        ttk.Radiobutton(connect,text='PC参考（不连接开发板）',variable=self.transport,value='offline').pack(side='left')
        ttk.Radiobutton(connect,text='FPGA实测',variable=self.transport,value='board').pack(side='left',padx=6)
        self.portbox=ttk.Combobox(connect,textvariable=self.port,width=12);self.portbox.pack(side='left')
        self.button(connect,'刷新COM',self.refresh_ports).pack(side='left',padx=4)
        ttk.Label(connect,text='115200 / 8N1').pack(side='left')
        self.modebox=ttk.Combobox(connect,textvariable=self.mode,values=list(MODES.values()),state='readonly',width=19)
        self.modebox.pack(side='left',padx=8)
        ttk.Checkbutton(connect,text='依次比较五模式',variable=self.compare).pack(side='left')
        panel=ttk.Frame(root,padding=8);panel.pack(fill='x')
        for key,var in self.params.items():
            ttk.Label(panel,text=key).pack(side='left');ttk.Entry(panel,textvariable=var,width=4).pack(side='left',padx=(2,6))
        ttk.Checkbutton(panel,text='使用已冻结参数（覆盖上方手动值）',variable=self.frozen).pack(side='left')
        options=ttk.Frame(root,padding=(8,0));options.pack(fill='x')
        ttk.Label(options,text='期望条码文本（保留前导零，可空）').pack(side='left')
        ttk.Entry(options,textvariable=self.expected,width=26).pack(side='left',padx=6)
        self.button(options,'开始处理并保存',self.start).pack(side='left',padx=6)
        ttk.Button(options,text='取消后续模式',command=self.cancel).pack(side='left')
        ttk.Button(options,text='查看结果目录',command=self.show_path).pack(side='left',padx=6)
        exact=ttk.Frame(root,padding=(8,6));exact.pack(fill='x')
        ttk.Label(exact,text='精确ROI（原图坐标 x0,y0,x1,y1）').pack(side='left')
        self.roi_entry=ttk.Entry(exact,textvariable=self.roi_text,width=30);self.roi_entry.pack(side='left',padx=6)
        self.button(exact,'应用ROI',self.apply_exact_roi).pack(side='left',padx=4)
        ttk.Checkbutton(exact,text='实拍自动定位（解码辅助选框）',variable=self.auto_roi_enabled,command=self.auto_locate).pack(side='left',padx=8)
        self.button(exact,'重新自动定位',self.auto_locate).pack(side='left')
        previews=ttk.Frame(root,padding=8);previews.pack(fill='x')
        left=ttk.LabelFrame(previews,text='输入图片：拖框选择ROI（框内需包含左右安静区）');left.pack(side='left')
        self.canvas=tk.Canvas(left,width=680,height=330,bg='#e9edf1',highlightthickness=0);self.canvas.pack()
        self.canvas.bind('<ButtonPress-1>',self.drag_start);self.canvas.bind('<B1-Motion>',self.drag_move)
        self.canvas.bind('<ButtonRelease-1>',self.drag_end)
        right=ttk.LabelFrame(previews,text='保持比例 + 补白后的实际输入');right.pack(side='left',fill='both',expand=True,padx=10)
        self.roi_label=ttk.Label(right);self.roi_label.pack(padx=8,pady=20)
        self.geometry_label=ttk.Label(right,text='');self.geometry_label.pack()
        self.tabs=ttk.Notebook(root);self.tabs.pack(fill='both',expand=True,padx=8,pady=8)
        self.result_labels={}
        for mode in MODES:
            frame=ttk.Frame(self.tabs);self.tabs.add(frame,text=MODES[mode])
            label=ttk.Label(frame);label.pack(side='left',padx=15,pady=10)
            text=ttk.Label(frame,text='未运行',justify='left',wraplength=650);text.pack(side='left',padx=12)
            self.result_labels[mode]=(label,text)
        ttk.Label(root,textvariable=self.status,wraplength=1120,padding=8).pack(fill='x')
        root.protocol('WM_DELETE_WINDOW',self.close);root.after(100,self.poll)
        self.refresh_ports()

    def button(self,parent,text,command):
        b=ttk.Button(parent,text=text,command=command);self.controls.append(b);return b

    def refresh_ports(self):
        from serial.tools import list_ports
        ports=[p.device for p in list_ports.comports()];self.portbox['values']=ports
        if ports and self.port.get() not in ports:self.port.set(ports[0])

    def open_image(self):
        name=filedialog.askopenfilename(filetypes=[('Images','*.png *.jpg *.jpeg *.bmp'),('All files','*.*')])
        if not name:return
        try:self.set_image(ImageOps.exif_transpose(Image.open(name)).convert('RGB'))
        except Exception as e:messagebox.showerror('读取失败',str(e))

    def set_image(self,image,auto=True):
        self.camera_stop.set();self.image=image.copy();self.roi_box=None
        self.auto_roi_info=None;self.auto_error=None
        self.clear_results()
        if auto and self.auto_roi_enabled.get():self.auto_locate()
        else:self.refresh_image();self.refresh_roi()

    def clear_results(self):
        for label,text in self.result_labels.values():
            label.configure(image='');text.configure(text='未运行（图片或ROI已变化）')

    def photo_parameters(self):
        if self.frozen.get():
            profile=json.loads((ROOT/'results/frozen_profile.json').read_text(encoding='utf-8'))
            return {m:DEFAULTS.copy() if m==1 else profile['selected_parameters'][str(m)].copy() for m in MODES}
        values={k:int(v.get()) for k,v in self.params.items()}
        return {m:values.copy() for m in MODES}

    def auto_locate(self):
        if self.busy or self.image is None:return
        self.clear_results();self.auto_roi_info=None;self.auto_error=None
        if self.auto_roi_enabled.get():
            try:
                self.roi_box,self.auto_roi_info=auto_select_roi(self.image,self.photo_parameters())
                n=self.auto_roi_info['selected']['score'][0]
                self.status.set(f'自动定位完成：{n}/{len(MODES)}个模式解码一致（尚未与期望文本核对，非实板结果）。点击开始处理并保存。')
            except Exception as e:
                self.roi_box=None;self.auto_error=str(e)
                self.status.set('自动定位失败：'+str(e))
        else:self.status.set('已关闭自动定位，可手动框选。')
        self.refresh_image();self.refresh_roi()

    def load_standard_example(self):
        if self.busy:return
        try:
            source,box,expected=standard_sample(ROOT)
            self.auto_roi_enabled.set(False)
            self.set_image(ImageOps.exif_transpose(Image.open(source)).convert('RGB'),auto=False)
            self.roi_box=box;self.expected.set(expected)
            self.refresh_image();self.refresh_roi()
            self.status.set('已从固定数据清单载入 shadow_03、ROI和期望文本。保持PC参考，点击开始处理。')
        except Exception as e:messagebox.showerror('示例加载失败',str(e))

    def apply_exact_roi(self):
        if self.busy:return
        if self.image is None:messagebox.showinfo('ROI','请先读取图片或载入标准示例');return
        try:self.roi_box=parse_roi(self.roi_text.get(),self.image.size)
        except ValueError as e:messagebox.showerror('ROI坐标错误',str(e));return
        self.auto_roi_enabled.set(False);self.auto_roi_info=None;self.clear_results()
        self.refresh_image();self.refresh_roi()
        self.status.set('精确ROI已应用。点击开始处理，重新计算本次结果。')

    def refresh_image(self,frame=None):
        image=frame if frame is not None else self.image
        if image is None:return
        thumb=image.copy();thumb.thumbnail((680,330));self.preview_size=thumb.size
        self.photos['input']=ImageTk.PhotoImage(thumb);self.canvas.delete('all')
        self.canvas.create_image(0,0,anchor='nw',image=self.photos['input'])
        if self.roi_box and frame is None:
            sx,sy=thumb.width/image.width,thumb.height/image.height
            x0,y0,x1,y1=self.roi_box
            self.canvas.create_rectangle(x0*sx,y0*sy,x1*sx,y1*sy,outline='#e74c3c',width=2,tags='roi')

    def refresh_roi(self):
        if self.image is None:return
        roi,meta=prepare_roi(self.image,box=self.roi_box)
        self.photos['roi']=ImageTk.PhotoImage(roi.resize((384,192),Image.Resampling.NEAREST))
        self.roi_label.configure(image=self.photos['roi'])
        self.geometry_label.configure(text=f"ROI {meta['roi_box']}\n缩放后 {meta['resized_size']}，画布192x96")
        self.roi_text.set(','.join(map(str,meta['roi_box'])))

    def reset_roi(self):
        if self.auto_roi_enabled.get():self.auto_locate();return
        self.roi_box=None;self.auto_roi_info=None;self.clear_results();self.refresh_image();self.refresh_roi()

    def drag_start(self,event):
        if self.busy or self.image is None:return
        self.drag=(event.x,event.y)
    def drag_move(self,event):
        if not self.drag:return
        self.canvas.delete('roi');self.canvas.create_rectangle(*self.drag,event.x,event.y,outline='#e74c3c',width=2,tags='roi')
    def drag_end(self,event):
        if not self.drag or self.image is None:return
        ax,ay=self.drag;self.drag=None;pw,ph=self.preview_size
        def clamp(v,limit):return max(0,min(limit,v))
        x0,x1=sorted((clamp(ax,pw),clamp(event.x,pw)));y0,y1=sorted((clamp(ay,ph),clamp(event.y,ph)))
        if x1-x0<3 or y1-y0<3:return
        self.auto_roi_enabled.set(False);self.auto_roi_info=None;self.clear_results()
        self.roi_box=(int(x0*self.image.width/pw),int(y0*self.image.height/ph),
                      int(x1*self.image.width/pw),int(y1*self.image.height/ph))
        self.refresh_image();self.refresh_roi()

    def start_camera(self):
        try:index=int(self.cam_index.get())
        except ValueError:messagebox.showerror('摄像头','序号应为整数，例如0');return
        self.camera_stop.set();self.camera_stop=threading.Event();event=self.camera_stop
        self.camera_frame=None;self.status.set('正在打开摄像头；预览成功后点击拍摄并冻结。')
        def work():
            cap=None
            try:
                import cv2
                cap=cv2.VideoCapture(index)
                if not cap.isOpened():raise RuntimeError('摄像头无法打开；请改用图片输入或检查权限')
                while not event.is_set():
                    ok,frame=cap.read()
                    if not ok:raise RuntimeError('摄像头读取失败；旧画面不会作为新照片使用')
                    self.queue.put(('frame',Image.fromarray(cv2.cvtColor(frame,cv2.COLOR_BGR2RGB))))
                    event.wait(.12)
            except Exception as e:self.queue.put(('camera_error',str(e)))
            finally:
                if cap:cap.release()
        threading.Thread(target=work,daemon=True).start()

    def capture(self):
        if self.camera_frame is None:messagebox.showinfo('拍摄','尚未收到摄像头画面，请先预览');return
        self.set_image(self.camera_frame)

    def set_busy(self,value):
        self.busy=value
        for control in self.controls:control.configure(state='disabled' if value else 'normal')

    def start(self):
        if self.busy:return
        if self.image is None:messagebox.showinfo('输入','请先读取图片或拍摄');return
        # Freeze every Tk value on the main thread before worker starts.
        try:
            if self.auto_roi_enabled.get():
                self.auto_locate()
                if self.auto_error or self.roi_box is None:raise ValueError(self.auto_error or '自动定位失败')
            modes=list(MODES) if self.compare.get() else [int(self.mode.get()[0])]
            params={k:int(v.get()) for k,v in self.params.items()}
            if self.frozen.get():
                frozen=load_profile(ROOT/'data/formal_v3',ROOT/'results/frozen_profile.json')
                per_mode={m:DEFAULTS if m==1 else frozen['selected_parameters'][str(m)] for m in modes}
            else:per_mode={m:params.copy() for m in modes}
            configs=[Config(sequence=i+1,mode=m,width=192,height=96,**per_mode[m]) for i,m in enumerate(modes)]
            for c in configs:c.validate()
            port=self.port.get().strip() if self.transport.get()=='board' else None
            if self.transport.get()=='board' and not port:raise ValueError('请选择实际COM口')
            source=self.image.copy();roi,meta=prepare_roi(source,box=self.roi_box)
            meta['host_pipeline']='experimental_photo_auto_v4.1' if self.auto_roi_info else 'manual_or_standard'
            meta['auto_roi']=self.auto_roi_info
            expected=self.expected.get().strip();folder=fresh_run('gui_board' if port else 'gui_reference')
        except Exception as e:messagebox.showerror('配置错误',str(e));return
        self.camera_stop.set();self.stop.clear();self.set_busy(True);self.last_run=folder
        for label,text in self.result_labels.values():
            label.configure(image='');text.configure(text='未运行')
        self.status.set('正在处理；所有模式使用同一冻结输入。取消会等待当前帧完成。')
        def work():
            from contextlib import nullcontext
            rows=[];status='RUNNING';failure=None;failure_details=''
            try:
                folder.mkdir(parents=True,exist_ok=False)
                source.save(folder/'input.png');roi.save(folder/'roi.png');dump_json(folder/'roi_geometry.json',meta)
                with BoardSession(port) if port else nullcontext(None) as session:
                    for cfg in configs:
                        if self.stop.is_set():status='CANCELLED';break
                        destination=folder/f'mode{cfg.mode}'
                        row=run_one(rgb565(roi),cfg,destination,expected,session=session,
                                    source=folder/'input.png',roi=folder/'roi.png')
                        rows.append(row);self.queue.put(('result',(cfg.mode,row,destination)))
                        if row['error']:raise RuntimeError(row['error'])
                    else:status='PASS'
            except Exception as e:
                status='FAIL';failure=f'{type(e).__name__}: {e}';failure_details=traceback.format_exc()
                self.queue.put(('error',failure))
            finally:
                summary=completion_message(status,expected,rows,failure)
                if folder.exists():
                    dump_json(folder/'report.json',{'status':status,
                        'evidence_type':('board_attempt_failed' if status=='FAIL' else 'board_current_run') if port else 'pc_reference_only',
                        'requested_port':port,'expected_text':expected,'failure':failure,
                        'summary':summary,'roi_geometry':meta,'rows':rows})
                    save_table(folder/'modes.csv',rows)
                    if failure_details:(folder/'error.log').write_text(failure_details,encoding='utf-8')
                self.queue.put(('finished',(status,folder,summary)))
        threading.Thread(target=work,daemon=True).start()

    def cancel(self):
        if self.busy:self.stop.set();self.status.set('已请求取消：等待当前帧完成，随后停止后续模式。')

    def show_path(self):
        messagebox.showinfo('结果目录',str(self.last_run or ROOT/'runs'))

    def poll(self):
        try:
            while True:
                kind,payload=self.queue.get_nowait()
                if kind=='frame':
                    if not self.camera_stop.is_set() and not self.busy:
                        self.camera_frame=payload;self.refresh_image(payload)
                elif kind=='camera_error':
                    self.camera_frame=None;self.camera_stop.set();self.status.set('摄像头失败：'+payload)
                elif kind=='result':
                    mode,row,folder=payload;image=folder/('fpga_common.png' if row['evidence_type']=='board_current_run' else 'reference_common.png')
                    if image.exists():
                        shown=Image.open(image);shown=shown.resize((shown.width*2,shown.height*2),Image.Resampling.NEAREST)
                        self.photos[mode]=ImageTk.PhotoImage(shown);self.result_labels[mode][0].configure(image=self.photos[mode])
                    tag='FPGA实测' if row['evidence_type']=='board_current_run' else 'PC参考' if row['evidence_type']=='pc_reference_only' else '实测失败'
                    self.result_labels[mode][1].configure(text=f"{tag}\n解码：{row.get('decoded_texts',[])}\n文本完全一致：{row.get('exact_match')}\n差异像素：{row.get('mismatch_count')}\nUART往返秒：{row.get('round_trip_s')}\n{row.get('error') or ''}")
                elif kind=='error':self.status.set('失败：'+payload)
                elif kind=='finished':
                    status,folder,summary=payload;self.set_busy(False)
                    self.status.set(f'{summary}；记录：{folder}')
                    if status=='FAIL':messagebox.showerror('处理失败（期望文本已保留）',f'{summary}\n\n详细错误已保存：\n{folder}')
                    if self.close_after:self.root.destroy();return
        except Empty:pass
        self.root.after(100,self.poll)

    def close(self):
        self.camera_stop.set()
        if self.busy:
            self.close_after=True;self.cancel();return
        self.root.destroy()


def launch():
    root=tk.Tk();App(root);root.mainloop()

if __name__=='__main__':launch()
