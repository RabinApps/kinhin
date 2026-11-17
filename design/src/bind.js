const g=figma.graph; const byName={}; for (const v of g.variables.values()) byName[v.name]=v.id;
const sizeVar={12:'type/caption',13:'type/body',15:'type/heading',17:'type/title',22:'type/display'};
const radVar={2:'radius/2',4:'radius/4',6:'radius/6',8:'radius/8',12:'radius/12'};
const spVar={2:'space/2',4:'space/4',8:'space/8',12:'space/12',16:'space/16',20:'space/20',24:'space/24'};
const st={text:0,radius:0,space:0,font:0,miss:0,err:0};
const famVar={'SF Pro Text':'font/text','SF Pro Display':'font/display'};
for (const n of g.nodes.values()) {
  try {
    if (n.type==='TEXT') { const id=byName[sizeVar[Math.round(n.fontSize)]]; if(id){ g.bindVariable(n.id,'fontSize',id); st.text++; } else st.miss++; const fam=(n.fontName&&n.fontName.family)||n.fontFamily; const fid=byName[famVar[fam]]; if(fid){ g.bindVariable(n.id,'fontFamily',fid); st.font++; } }
    else if (n.type==='FRAME') {
      if (typeof n.cornerRadius==='number' && n.cornerRadius>0) { const id=byName[radVar[n.cornerRadius]]; if(id){ g.bindVariable(n.id,'cornerRadius',id); st.radius++; } }
      if (n.layoutMode && n.layoutMode!=='NONE') {
        for (const p of ['itemSpacing','paddingLeft','paddingRight','paddingTop','paddingBottom']) { const id=byName[spVar[n[p]]]; if(id){ g.bindVariable(n.id,p,id); st.space++; } }
      }
    }
  } catch(e) { st.err++; }
}
return st;
