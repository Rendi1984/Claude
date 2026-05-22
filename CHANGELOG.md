# Changelog

## v1.0.1 — תיקוני באגים
**קומיט:** `b4caaec`

### תוקן
- כפתור תשובה נשאר מסומן ב-Safari iOS — תוקן ע"י ניקוי GPU layer לפני רנדור שאלה חדשה
- Toast מכסה רמז במשחק "תפוס מילה" — הוזז לראש המסך
- משחק "תפוס מילה" נתקע כשמילת פיתוי נופלת לפני המילה הנכונה — תוקן

---

## v1.0.0 — גרסה ראשונה
**קומיט:** `d4229b8`

### פיצ'רים
- אפליקציית לימוד אנגלית מלאה
- תמיכה ב-Safari / iOS:
  - localStorage עם fallback ל-sessionStorage
  - Web Speech API עם בדיקת תמיכה
  - מטא-תגים ל-iOS (apple-mobile-web-app-capable)
- מספר גרסה בתפריט הגדרות

---

## איך לחזור לגרסה קודמת?

### דרך GitHub (ממשק ויזואלי)
1. כנס ל: `github.com/Rendi1984/Claude/commits/claude/check-github-access-o61GB`
2. לחץ על הקומיט שאליו רוצים לחזור
3. העתק את ה-SHA (קוד הקומיט)
4. לחץ **Browse files** לצפייה בגרסה ההיא

### דרך Git (מתקדם)
```bash
# צפייה בגרסה ישנה
git checkout d4229b8 -- english_v3_5.html

# חזרה לגרסה האחרונה
git checkout HEAD -- english_v3_5.html
```
