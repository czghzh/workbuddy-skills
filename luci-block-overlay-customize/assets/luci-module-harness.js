#!/usr/bin/env node
/*
 * luci-module-harness.js — 在 node 里跑 LuCI 前端模块的通用骨架
 * ============================================================
 *
 * 目的：不刷机、不开浏览器，就把 LuCI 的 JS 模块真的执行一遍，
 *       喂它设备实测值，检查取数与渲染是否如预期；顺带能把元素树
 *       序列化成预览 HTML。
 *
 * 用法：把本文件拷成目标项目里的 selftest.js / mock-render.js，按
 *       «用法注释» 改顶部 3 处路径 + 中部的 FILES 实测值即可。
 *
 *   node selftest.js       -> 打印断言结果，末行「全部通过」
 *   node mock-render.js    -> 另存 preview.html
 *
 * 为什么需要这些桩：LuCI 模块长这样 ——
 *
 *     'use strict';
 *     'require baseclass';
 *     'require fs';
 *     return baseclass.extend({ title: _('X'), load(){...}, render(data){...} });
 *
 * 把 'require ...' 行剥掉、new Function 执行，LuCI 的全局就是普通变量了。
 */
'use strict';

const fs   = require('fs');
const path = require('path');

/* ---------------------------------------------------------------- *
 * 用法注释 ①：改成你的模块路径
 * ---------------------------------------------------------------- */
const BASE    = path.join(__dirname, 'files/www/luci-static/resources');
const HW_SRC  = path.join(BASE, 'hardware_status.js');                 // 数据模块
const SYS_SRC = path.join(BASE, 'view/status/include/10_system.js');   // 渲染模块

/* ---------------------------------------------------------------- *
 * 用法注释 ②：填设备实测值（原样贴出来，别"美化"）
 * ---------------------------------------------------------------- */
const FILES = {
	'/sys/class/thermal/thermal_zone0/temp': '77900\n',
	'/sys/class/hwmon/hwmon0/name':          'mt7915_phy0\n',
	'/sys/class/hwmon/hwmon0/temp1_input':   '69000\n',
	'/sys/class/hwmon/hwmon1/name':          'mt7915_phy1\n',
	'/sys/class/hwmon/hwmon1/temp1_input':   '69000\n',
	'/sys/kernel/debug/airoha-xpon-pon0/frontend':
		'error: 0\ncalibration: ready\ntx_gate_enabled: 0\n' +
		'temperature_8472: 0x3f13\nvoltage_8472: 0x7ffd\n',
	'/sys/kernel/debug/ppe/config':
		'npu_attached: 0\ngdm2_fwd_cfg: 07f18888\n',
	'/proc/stat': 'cpu  1635 0 2966 335102 116 0 83 0 0 0\n'
};
/* 第二次采样（首帧二次采样路径会用到的"下一拍"值） */
const STAT2 = 'cpu  1700 0 3100 336000 120 0 90 0 0 0\n';
const EXEC_OUT = 'tcp_total=1\ntcp_npu=0\nudp_total=11\nudp_npu=0\n';

/* ---------------------------------------------------------------- *
 * LuCI 全局桩
 * ---------------------------------------------------------------- */
let statCalls = 0;

global.fs = {
	trimmed(p) {
		if (p === '/proc/stat')
			return Promise.resolve(((++statCalls % 2) ? FILES[p] : STAT2).trim());
		return Promise.resolve(FILES[p] !== undefined ? FILES[p].trim() : '');
	},
	read(p) { return this.trimmed(p); },
	list() { return Promise.resolve([]); },
	exec() { return Promise.resolve({ code: 0, stdout: EXEC_OUT }); }
};

global.L = {
	resolveDefault: (p, d) => Promise.resolve(p).catch(() => d),
	isObject: (v) => v != null && typeof v === 'object',
	env: { pollinterval: 5 }
};

global._ = (s) => s;                       /* 不做 i18n，返回原文 */

/* 极简"元素树"取代真 DOM */
global.E = function E(tag, attrs, children) {
	const node = { tag, attrs: attrs || {}, children: [] };
	const list = (children == null) ? [] : (Array.isArray(children) ? children : [children]);
	for (const c of list) if (c != null) node.children.push(c);   /* 丢掉 null 子节点 */
	node.appendChild = (c) => { node.children.push(c); return c; };
	return node;
};

global.baseclass = { extend: (o) => o };
global.rpc = { declare: () => () => Promise.resolve({}) };

/* ⚠️ 必须有：模块里合法地用 window.setTimeout 做首帧二次采样，
 *    不加这个桩会报 "ReferenceError: window is not defined" */
global.window = { setTimeout: (fn, ms) => setTimeout(fn, ms) };

global.uci = {
	load: () => Promise.resolve(),
	/* zonename 必须是合法 IANA 名，否则 render 里 Intl.DateTimeFormat 会抛 RangeError */
	get: (s, x, o) => (o === 'zonename' ? 'Asia/Shanghai' : 0)
};

/* String.prototype.format 的最小可用版（cbi.js 里那个）。
 * 真实实现有个坑：第一个 % 不是合法转换符时整串原样返回 —— 所以
 * 待测模块的 CSS 字符串不该走 .format()，这里也不模拟那个坑。 */
String.prototype.format = function () {
	const args = Array.prototype.slice.call(arguments);
	let i = 0;
	return String(this).replace(/%[0-9.]*([sdifut])/g, (m, t) => {
		const v = args[i++];
		if (t === 'f') {
			const prec = (m.match(/\.(\d+)/) || [])[1];
			return Number(v || 0).toFixed(prec !== undefined ? Number(prec) : 0);
		}
		if (t === 't') {   /* 秒 -> "2d 3h 4m 5s"，LuCI 的 uptime 格式 */
			let s = Number(v || 0), mm = Math.floor(s / 60); s %= 60;
			let h = Math.floor(mm / 60); mm %= 60;
			const d = Math.floor(h / 24); h %= 24;
			return (d ? d + 'd ' : '') + (h ? h + 'h ' : '') + (mm ? mm + 'm ' : '') + s + 's';
		}
		return String(v);
	});
};

/* ---------------------------------------------------------------- *
 * 模块加载：剥掉 require 行 + 去掉 'use strict'
 * ---------------------------------------------------------------- */
function loadModule(file, extra) {
	const src = fs.readFileSync(file, 'utf8')
		.replace(/^'require [a-z_.]+';$/gm, '')
		.replace(/^'use strict';$/gm, '');
	if (extra) Object.assign(global, extra);
	return new Function(src)();
}

/* ---------------------------------------------------------------- *
 * 元素树工具
 * ---------------------------------------------------------------- */
function text(node, out = []) {          /* 收集所有文本，用于 includes() 断言 */
	if (node == null) return out;
	if (typeof node === 'string' || typeof node === 'number') { out.push(String(node)); return out; }
	if (node.children) for (const c of node.children) text(c, out);
	return out;
}

function esc(s) {
	return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
		.replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function html(node) {                    /* 元素树 -> HTML 串 */
	if (node == null) return '';
	if (typeof node === 'string' || typeof node === 'number') return esc(node);
	let a = '';
	for (const k in node.attrs)
		if (node.attrs[k] != null) a += ' ' + k + '="' + esc(node.attrs[k]) + '"';
	return '<' + node.tag + a + '>' + (node.children || []).map(html).join('') + '</' + node.tag + '>';
}

function dump(node, indent = '') {        /* 肉眼扫一遍结构 */
	if (typeof node === 'string' || typeof node === 'number') { console.log(indent + node); return; }
	console.log(indent + '<' + node.tag + '>');
	for (const c of node.children) dump(c, indent + '  ');
}

/* ---------------------------------------------------------------- *
 * 断言
 * ---------------------------------------------------------------- */
let failed = 0;
function ok(name, cond, extra) {
	console.log((cond ? '  OK   ' : '  FAIL ') + name + (cond ? '' : '   ' + (extra || '')));
	if (!cond) failed++;
}
function eq(name, got, want) {
	const same = JSON.stringify(got) === JSON.stringify(want);
	ok(name, same, 'got=' + JSON.stringify(got) + ' want=' + JSON.stringify(want));
}

/* ---------------------------------------------------------------- *
 * 用法注释 ③：这里是每个项目要自己写的部分
 * ---------------------------------------------------------------- */
(async () => {
	console.log('=== 1) 数据模块 read() vs 设备实测值 ===');
	const hw = loadModule(HW_SRC);
	const hwdata = await hw.read();
	console.log(JSON.stringify(hwdata, null, 1));

	eq('temps',  hwdata.temps, [
		{ key: 'cpu', label: 'CPU', value: 77900 },
		{ key: 'wifi', label: 'WiFi', value: 69000 },
		{ key: 'pon',  label: 'PON',  value: 63074 }
	]);
	eq('npuAttached', hwdata.npuAttached, 0);

	console.log('\n=== 2) 渲染模块 render() 端到端 ===');
	/* 喂给 render() 的 data[] 必须与模块 load() 返回的 Promise.all 顺序严格一致 */
	const hw2 = loadModule(HW_SRC);
	const sys = loadModule(SYS_SRC, { hardware_status: hw2 });

	const now = Math.floor(Date.now() / 1000);
	const data = [
		{ hostname: 'ponwrt', model: 'ZNXT ZN515XG-D', system: 'ARMv8 Processor rev 4',
		  kernel: '6.18.52',
		  release: { target: 'airoha/an7581', description: 'PonWrt SNAPSHOT r41435' } },
		{ uptime: 766, load: [655, 402, 260] },
		{ cpubench: '' },
		{ cpuinfo: 'ARMv8 Processor rev 4 (v8l) x 4 (800MHz, 78.1\u00b0C)' },
		{ cpuusage: '3%' },
		{ branch: 'LuCI', revision: 'git-26.261.08411' },
		now,
		null,
		await hw2.read()
	];

	const tree = await sys.render(data);
	dump(tree);

	const flat = text(tree).join('|');
	ok('架构保留主频、只去掉温度',
		flat.includes('ARMv8 Processor rev 4 (v8l) x 4 (800MHz)') && !/78\.1/.test(flat));
	ok('温度行', flat.includes('CPU|77.9|°C'));

	/* ---- 顺带产出静态预览（不想产出就删掉这段） ---- */
	const out = path.join(__dirname, 'preview.html');
	fs.writeFileSync(out, '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
		'<title>preview</title></head><body><div class="cbi-section">' +
		html(tree) + '</div></body></html>');
	console.log('\nwrote ' + out);

	console.log('\n结果: ' + (failed ? '有 ' + failed + ' 项失败' : '全部通过'));
	process.exitCode = failed ? 1 : 0;
})();
